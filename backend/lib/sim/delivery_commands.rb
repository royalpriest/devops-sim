module Sim
  # Shell commands for the delivery chapters: git, the GitHub CLI (gh),
  # running the test suite, and a small deploy tool. Mixed into Shell.
  module DeliveryCommands
    private

    def repo = (@repo ||= Repo.new(world))
    def repo? = world.data.key?("repo") && world.current_host == Repo::HOST

    def in_repo
      return fail("fatal: not a git repository (or any of the parent directories): .git", 128) unless repo? && repo.inside?(world.session["cwd"])
      yield
    end

    # --- git ----------------------------------------------------------------

    def cmd_git(args)
      return fail("bash: git: command not found", 127) unless world.data.key?("repo")
      sub, *rest = args
      return ok("usage: git <command>\n\nTry: status, branch, switch -c, add, commit -m, log, diff, push, revert") unless sub
      in_repo do
        scenario.on_inspect(world, :git, sub)
        case sub
        when "status" then git_status
        when "branch" then git_branch(rest)
        when "checkout", "switch" then git_switch(rest)
        when "add" then git_add(rest)
        when "commit" then git_commit(rest)
        when "log" then git_log(rest)
        when "diff" then git_diff(rest)
        when "push" then git_push(rest)
        when "pull", "fetch" then ok("Already up to date.")
        when "revert" then git_revert(rest)
        when "restore" then git_restore(rest)
        else fail("git: '#{sub}' is not a git command in this simulator. Try `git` for a list.")
        end
      end
    end

    def git_status
      c = repo.changes
      lines = [ "On branch #{repo.branch}" ]
      pushed = world.data["repo"]["remote"][repo.branch]
      lines << (pushed == repo.head_sha ? "Your branch is up to date with 'origin/#{repo.branch}'." : pushed ? "Your branch is ahead of 'origin/#{repo.branch}'." : "Your branch is not on GitHub yet (git push -u origin #{repo.branch}).")
      lines << ""
      if c[:staged].any?
        lines += [ "Changes to be committed:" ] + c[:staged].map { |p| "\tmodified:   #{p}" } + [ "" ]
      end
      if c[:unstaged].any?
        lines += [ "Changes not staged for commit:", '  (use "git add <file>..." to update what will be committed)' ] +
                 c[:unstaged].map { |p| "\t#{repo.working_tree.key?(p) ? 'modified' : 'deleted'}:   #{p}" } + [ "" ]
      end
      if c[:untracked].any?
        lines += [ "Untracked files:" ] + c[:untracked].map { |p| "\t#{p}" } + [ "" ]
      end
      lines << "nothing to commit, working tree clean" if c.values.all?(&:empty?)
      ok(lines.join("\n").rstrip)
    end

    def git_branch(rest)
      return git_switch([ "-c", rest.first ]) if rest.first && !rest.first.start_with?("-")
      ok(world.data["repo"]["branches"].keys.sort.map { |b| b == repo.branch ? "* #{b}" : "  #{b}" }.join("\n"))
    end

    def git_switch(rest)
      create = rest.delete("-b") || rest.delete("-c")
      name = rest.first
      return fail("usage: git switch -c <new-branch>") unless name
      branches = world.data["repo"]["branches"]
      if create
        return fail("fatal: a branch named '#{name}' already exists") if branches.key?(name)
        return fail("fatal: '#{name}' is not a valid branch name (no spaces)") if name.match?(/\s/)
        branches[name] = repo.head_sha
        world.data["repo"]["branch"] = name
        return ok("Switched to a new branch '#{name}'")
      end
      return fail("error: pathspec '#{name}' did not match any branch. Use `git switch -c #{name}` to create it.") unless branches.key?(name)
      c = repo.changes
      return fail("error: you have uncommitted changes. Commit them first.") if (c[:staged] + c[:unstaged]).any?
      world.data["repo"]["branch"] = name
      repo.write_tree(repo.snapshot)
      ok("Switched to branch '#{name}'")
    end

    def git_add(rest)
      return fail("Nothing specified, nothing added.\nhint: Maybe you wanted to say 'git add .'?") if rest.empty?
      return (repo.stage_all || ok("")) && ok("") if rest.include?(".") || rest.include?("-A") || rest.include?("--all")
      paths = rest.map { |r| repo.rel(world.resolve(r)) }
      missing = paths.reject { |p| repo.working_tree.key?(p) || repo.index.key?(p) }
      return fail("fatal: pathspec '#{missing.first}' did not match any files") if missing.any?
      repo.stage(paths)
      ok("")
    end

    def git_commit(rest)
      repo.stage_all if rest.delete("-a") || rest.delete("-am")&.then { rest.unshift("-m") }
      i = rest.index("-m")
      message = i && rest[i + 1]
      return fail("Aborting commit: write a message with -m, for example:\n  git commit -m \"Add free shipping banner\"") if message.to_s.strip.empty?
      return fail("On branch #{repo.branch}\nnothing to commit (use \"git add\" to stage changes)") if repo.changes[:staged].empty?
      files = repo.changes[:staged].size
      sha = repo.commit!(message)
      scenario.on_commit(world, sha)
      ok("[#{repo.branch} #{sha}] #{message}\n #{files} file#{'s' unless files == 1} changed")
    end

    def git_log(rest)
      entries = repo.log.first(rest.include?("-1") ? 1 : 10)
      if rest.include?("--oneline")
        ok(entries.map { |sha, c| "#{sha} #{c['message']}" }.join("\n"))
      else
        ok(entries.map { |sha, c| "commit #{sha}\nAuthor: #{c['author']}\n\n    #{c['message']}\n" }.join("\n").rstrip)
      end
    end

    def git_diff(rest)
      ref = rest.find { |r| !r.start_with?("-") }
      if ref
        sha = world.data["repo"]["branches"][ref] || world.data["repo"]["commits"].keys.find { |s| s.start_with?(ref) }
        return fail("fatal: ambiguous argument '#{ref}': unknown revision") unless sha
        return ok(repo.diff(repo.snapshot(sha), repo.working_tree))
      end
      out = rest.include?("--staged") || rest.include?("--cached") ? repo.diff(repo.snapshot, repo.index) : repo.diff(repo.index, repo.working_tree)
      ok(out)
    end

    def git_restore(rest)
      paths = rest.reject { |r| r.start_with?("-") }.map { |r| repo.rel(world.resolve(r)) }
      paths.each { |p| repo.index[p] ? world.write_file(repo.abs(p), repo.index[p], Repo::HOST) : nil }
      ok("")
    end

    def git_push(rest)
      name = rest.reject { |r| r.start_with?("-") || r == "origin" }.first || repo.branch
      return fail("error: src refspec #{name} does not match any") unless world.data["repo"]["branches"].key?(name)
      remote = world.data["repo"]["remote"]
      was = remote[name]
      return ok("Everything up-to-date") if was == repo.head_sha(name)
      remote[name] = repo.head_sha(name)
      scenario.on_push(world, name)
      lines = [ "To github.com:shop/shop.git", was ? "   #{was}..#{remote[name]}  #{name} -> #{name}" : " * [new branch]      #{name} -> #{name}" ]
      if (pr = repo.pr_for(name))
        repo.start_run!(pr)
        lines << "CI started for pull request ##{pr['number']}. Check it with `gh pr checks`."
      elsif name != "main"
        lines += [ "", "remote: Create a pull request for '#{name}' on GitHub by running:", "remote:      gh pr create --title \"...\"" ]
      end
      ok(lines.join("\n"))
    end

    def git_revert(rest)
      sha = rest.reject { |r| r.start_with?("-") }.first
      return fail("usage: git revert <commit>") unless sha
      target = world.data["repo"]["commits"].keys.find { |s| s.start_with?(sha) }
      return fail("fatal: bad revision '#{sha}'") unless target
      parent = repo.commit(target)["parent"]
      reverted = repo.snapshot.dup
      (repo.snapshot(target).keys | repo.snapshot(parent).keys).each do |p|
        next if repo.snapshot(target)[p] == repo.snapshot(parent)[p]
        repo.snapshot(parent)[p] ? reverted[p] = repo.snapshot(parent)[p] : reverted.delete(p)
      end
      repo.write_tree(reverted)
      repo.stage_all
      message = "Revert \"#{repo.commit(target)['message']}\""
      new_sha = repo.commit!(message)
      scenario.on_commit(world, new_sha)
      ok("[#{repo.branch} #{new_sha}] #{message}")
    end

    # --- GitHub CLI -------------------------------------------------------

    def cmd_gh(args)
      return fail("bash: gh: command not found", 127) unless world.data.key?("repo")
      area, action, *rest = args
      in_repo do
        scenario.on_inspect(world, :gh, "#{area} #{action}")
        case [ area, action ]
        in [ "pr", "create" ] then gh_pr_create(rest)
        in [ "pr", "list" ] then gh_pr_list
        in [ "pr", "view" ] then gh_pr_view
        in [ "pr", "checks" ] then gh_pr_checks
        in [ "run", "view" ] then gh_run_view(rest)
        in [ "run", "list" ] then gh_pr_checks
        else ok("Work with GitHub from the terminal. Try:\n  gh pr create --title \"...\"\n  gh pr view\n  gh pr checks\n  gh run view --log-failed")
        end
      end
    end

    def gh_pr_create(rest)
      name = repo.branch
      return fail("You're on main. Make a branch first: git switch -c my-change") if name == "main"
      remote = world.data["repo"]["remote"][name]
      return fail("aborted: you must first push the current branch to GitHub, for example:\n  git push -u origin #{name}") unless remote
      return fail("a pull request for branch \"#{name}\" already exists:\n  #{pr_url(repo.pr_for(name))}") if repo.pr_for(name)
      i = rest.index("--title") || rest.index("-t")
      title = (i && rest[i + 1]) || (rest.include?("--fill") && repo.commit(remote)["message"])
      return fail("Give your pull request a title:\n  gh pr create --title \"Add free shipping banner\"") if title.to_s.strip.empty?
      pr = repo.open_pr!(title, name)
      scenario.on_pr(world, pr)
      ok("Creating pull request for #{name} into main in shop/shop\n\n#{pr_url(pr)}\n\nCI is running. Check it with `gh pr checks`.")
    end

    def pr_url(pr) = "https://github.com/shop/shop/pull/#{pr['number']}"

    def current_pr = repo.pr_for(repo.branch) || repo.prs.reverse.find { |p| p["state"] == "open" }

    def gh_pr_list
      open = repo.prs.select { |p| p["state"] == "open" }
      return ok("no open pull requests in shop/shop") if open.empty?
      ok(open.map { |p| "##{p['number']}  #{p['title']}  #{p['branch']}  #{run_label(repo.latest_run(p))}" }.join("\n"))
    end

    def gh_pr_view
      pr = current_pr or return fail("no pull requests found for branch \"#{repo.branch}\"")
      run = repo.latest_run(pr)
      ok([ "#{pr['title']} ##{pr['number']}", "Open · you wants to merge #{pr['branch']} into main".sub("you wants", "you want"),
           "", "Checks: #{run_label(run)}", "", pr_url(pr) ].join("\n"))
    end

    def run_label(run)
      return "no checks" unless run
      return "running..." if run["status"] == "in_progress"
      run["conclusion"] == "success" ? "all checks passed" : "1 failing check"
    end

    def gh_pr_checks
      pr = current_pr or return fail("no pull requests found for branch \"#{repo.branch}\"")
      run = repo.latest_run(pr) or return ok("no checks reported on the '#{pr['branch']}' branch")
      line =
        case run["status"]
        when "in_progress" then "*  test   running   (run #{run['id']})"
        else run["conclusion"] == "success" ? "✓  test   passed    (run #{run['id']})" : "X  test   failed    (run #{run['id']})"
        end
      code = run["conclusion"] == "failure" ? 1 : 0
      Shell::Result.new(output: "#{run_label(run).capitalize}\n\n#{line}\n\nSee the log with: gh run view #{run['id']} --log-failed", exit_code: code)
    end

    def gh_run_view(rest)
      pr = current_pr or return fail("no runs found")
      id = rest.find { |r| r.match?(/\A\d+\z/) }&.to_i
      run = id ? repo.prs.flat_map { |p| p["runs"] }.find { |r| r["id"] == id } : repo.latest_run(pr)
      return fail("could not find run #{id}") unless run
      return ok("Run #{run['id']} is still in progress. Try again in a moment.") if run["status"] == "in_progress"
      return ok("✓ Run #{run['id']} passed. All #{run['tests'] || 'the'} tests are green.") if run["conclusion"] == "success"
      ok(([ "X test · run #{run['id']} · failed", "" ] + run["log"]).join("\n"))
    end

    # --- tests ------------------------------------------------------------

    def cmd_rails(args)
      return fail("bash: rails: command not found", 127) unless world.data.key?("repo")
      return ok("Usage: bin/rails test") unless args.first == "test"
      in_repo do
        return fail("bin/rails: run this from the project root (cd ~/shop)") unless world.session["cwd"] == repo.root
        passed, lines = scenario.run_tests(world, repo.working_tree)
        scenario.on_inspect(world, :tests, passed ? "pass" : "fail")
        Shell::Result.new(output: lines.join("\n"), exit_code: passed ? 0 : 1)
      end
    end

    # --- deploys ------------------------------------------------------------

    def cmd_deploy(args)
      d = world.data["deploy"]
      return fail("bash: deploy: command not found", 127) unless d
      sub, *rest = args
      scenario.on_inspect(world, :deploy, sub.to_s)
      case sub
      when "status"
        r = release(d["current"])
        ok("Production: shop.example\nCurrent release: #{r['id']} (#{r['sha']} \"#{r['message']}\")\nDeployed: #{world.timestamp(r['at'])} by #{r['by']}\nHealth check: #{scenario.http(world, 'https://shop.example/health')&.first}")
      when "releases", "history"
        ok(([ "RELEASE  COMMIT   DEPLOYED          BY      MESSAGE" ] + d["releases"].reverse.map { |r|
          format("%-8s %-8s %-17s %-7s %s%s", r["id"], r["sha"], world.timestamp(r["at"])[0, 15], r["by"], r["message"], r["id"] == d["current"] ? "  <- live" : "")
        }).join("\n"))
      when "logs"
        ok(Array(d["logs"]).last(rest.include?("-n") ? rest[rest.index("-n") + 1].to_i : 12).join("\n"))
      when "rollback"
        target = rest.first || d["releases"][-2]&.dig("id")
        r = release(target) or return fail("deploy: no release called #{target}. See `deploy releases`.")
        return ok("#{r['id']} is already live.") if r["id"] == d["current"]
        d["current"] = r["id"]
        scenario.on_rollback(world, r)
        ok("Rolling back production to #{r['id']} (#{r['sha']})...\n  ✓ Switched web-01 to #{r['id']}\n  ✓ Restarted shop-web\nDone. #{r['id']} is live.")
      else
        ok("deploy: ship and roll back the shop.\n\n  deploy status            what is live right now\n  deploy releases          recent releases\n  deploy logs              recent app logs from production\n  deploy rollback <id>     put an earlier release back")
      end
    end

    def release(id) = world.data["deploy"]["releases"].find { |r| r["id"] == id }
  end
end
