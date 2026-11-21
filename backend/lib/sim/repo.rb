require "digest"

module Sim
  # A tiny git: enough to teach branch, add, commit, push, revert and pull
  # requests. The working tree is the laptop's real (simulated) files under
  # `root`; commits store full snapshots, which keeps everything simple.
  #
  # world["repo"] = {
  #   "root", "branch", "staged" => { path => content|nil },
  #   "commits" => { sha => { "message", "parent", "files", "author", "tick" } },
  #   "branches" => { name => sha }, "remote" => { name => sha },
  #   "prs" => [ { "number", "title", "branch", "state", "runs" => [...] } ]
  # }
  class Repo
    HOST = "laptop".freeze

    attr_reader :world

    def initialize(world)
      @world = world
    end

    def data = world.data["repo"]
    def root = data["root"]
    def branch = data["branch"]
    def head_sha(name = branch) = data["branches"][name]
    def commit(sha) = data["commits"].fetch(sha)
    def snapshot(sha = head_sha) = sha ? commit(sha)["files"] : {}
    def prs = data["prs"]
    def pr_for(name) = prs.find { |p| p["branch"] == name && p["state"] == "open" }

    def inside?(path) = path == root || path.start_with?(root + "/")
    def rel(path) = path.delete_prefix(root + "/")
    def abs(rel_path) = File.join(root, rel_path)

    # Files in the working tree, relative to the repo root.
    def working_tree
      tree = world.files(HOST).each_with_object({}) do |(path, f), out|
        out[rel(path)] = f["content"].to_s if inside?(path) && path != root
      end
      ignored = tree[".gitignore"].to_s.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
      tree.reject { |p, _| ignored.any? { |pat| p == pat || p.start_with?(pat.end_with?("/") ? pat : "#{pat}/") } }
    end

    # Files git ignores but that still affect the laptop (like .env).
    def ignored_file(rel_path) = world.file(abs(rel_path), HOST)&.dig("content")

    # What `git commit` would record: HEAD with the staged changes on top.
    def index
      snapshot.merge(data["staged"]).compact
    end

    def changes
      tree = working_tree
      idx = index
      head = snapshot
      {
        staged: (idx.keys | head.keys).select { |p| idx[p] != head[p] }.sort,
        unstaged: idx.keys.select { |p| tree.key?(p) ? tree[p] != idx[p] : true }.sort,
        untracked: (tree.keys - idx.keys).sort
      }
    end

    def stage(paths)
      tree = working_tree
      paths.each { |p| data["staged"][p] = tree[p] } # nil means "deleted"
    end

    def stage_all
      tree = working_tree
      (tree.keys | index.keys).each { |p| data["staged"][p] = tree[p] }
    end

    def commit!(message, author: "you")
      files = index
      sha = Digest::SHA1.hexdigest("#{head_sha}#{message}#{files.hash}#{world.clock}")[0, 7]
      data["commits"][sha] = { "message" => message, "parent" => head_sha, "files" => files, "author" => author, "tick" => world.clock }
      data["branches"][branch] = sha
      data["staged"] = {}
      sha
    end

    # Make the working tree match a commit (used by checkout and revert).
    def write_tree(files)
      world.files(HOST).keys.select { |p| inside?(p) && p != root }.each { |p| world.delete_file(p, HOST) }
      files.each { |p, content| world.write_file(abs(p), content, HOST) }
    end

    def log(sha = head_sha)
      out = []
      while sha
        out << [ sha, commit(sha) ]
        sha = commit(sha)["parent"]
      end
      out
    end


    # Simple line diff: removed lines then added lines, per file.
    def diff(from, to)
      (from.keys | to.keys).sort.filter_map do |path|
        next if from[path] == to[path]
        old_lines = from[path].to_s.lines.map(&:chomp)
        new_lines = to[path].to_s.lines.map(&:chomp)
        removed = old_lines - new_lines
        added = new_lines - old_lines
        [ "diff --git a/#{path} b/#{path}", "--- a/#{path}", "+++ b/#{path}",
          *removed.map { |l| "-#{l}" }, *added.map { |l| "+#{l}" } ].join("\n")
      end.join("\n")
    end

    # --- pull requests and CI -------------------------------------------

    def open_pr!(title, name = branch)
      number = (prs.map { |p| p["number"] }.max || 11) + 1
      pr = { "number" => number, "title" => title, "branch" => name, "state" => "open", "runs" => [] }
      prs << pr
      start_run!(pr)
      pr
    end

    def start_run!(pr)
      sha = data["remote"][pr["branch"]]
      return if pr["runs"].any? { |r| r["sha"] == sha }
      pr["runs"] << { "id" => 7000 + world.clock * 10 + pr["runs"].size, "sha" => sha, "status" => "in_progress",
                      "started" => world.clock, "conclusion" => nil, "log" => [] }
    end

    def latest_run(pr) = pr["runs"].last
  end
end
