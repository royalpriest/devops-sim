require "shellwords"

module Sim
  # Interprets what the player types into the fake terminal. It understands a
  # small, realistic subset of bash: sudo, pipes into simple filters, `&&`,
  # and `>` / `>>` redirection. Every command reads and changes the World;
  # nothing ever touches the real machine.
  class Shell
    include DeliveryCommands

    Result = Struct.new(:output, :exit_code, keyword_init: true)

    FILTERS = %w[grep head tail sort wc].freeze

    def initialize(world, scenario)
      @world = world
      @scenario = scenario
    end

    def run(input)
      input = input.to_s.strip
      return Result.new(output: "", exit_code: 0) if input.empty?

      outputs = []
      code = 0
      input.split(/\s*&&\s*/).each do |segment|
        result = run_pipeline(segment)
        outputs << result.output unless result.output.empty?
        code = result.exit_code
        break unless code.zero?
      end
      Result.new(output: outputs.join("\n"), exit_code: code)
    end

    private

    attr_reader :world, :scenario

    def run_pipeline(segment)
      stages = segment.split(/\s+\|\s+/)
      first, redirect = split_redirect(stages.shift)
      argv = tokenize(first)
      return argv if argv.is_a?(Result)

      result = dispatch(argv, redirect: redirect)
      stages.each do |stage|
        filter = tokenize(stage)
        return filter if filter.is_a?(Result)
        result = apply_filter(filter, result.output)
      end
      result
    end

    def tokenize(text)
      Shellwords.split(text.to_s)
    rescue ArgumentError
      Result.new(output: "bash: syntax error: unmatched quote", exit_code: 2)
    end

    def split_redirect(text)
      if (m = text.match(/\A(.*?)\s*(>>?)\s*(\S+)\s*\z/)) && !text.start_with?("sed ")
        [ m[1].presence || ":", { mode: m[2], path: m[3] } ]
      else
        [ text, nil ]
      end
    end

    def dispatch(argv, redirect: nil, sudo: false)
      name, *args = argv
      return dispatch(args, redirect: redirect, sudo: true) if name == "sudo" && args.any?
      return ok("usage: sudo command") if name == "sudo"

      @sudo = sudo || root?
      args = args.flat_map { |a| expand_glob(a) } unless %w[grep sed echo].include?(name)
      name = "rails" if %w[bin/rails ./bin/rails].include?(name)
      handler = "cmd_#{name.to_s.tr('-', '_')}"
      result =
        if name == ":" then ok("")
        elsif respond_to?(handler, true) && !command_available?(name)
          fail("#{name}: this is your laptop. The services run on the servers, so `ssh web-01` first.", 127)
        elsif respond_to?(handler, true) then send(handler, args)
        else fail("bash: #{name}: command not found", 127)
        end
      redirect ? write_redirect(result, redirect) : result
    end

    def command_available?(name)
      remote_only = %w[systemctl journalctl]
      !(remote_only.include?(name) && !world.host["linux_server"])
    end

    # `/var/log/*` style globs, matched against one directory level like bash.
    def expand_glob(arg)
      return [ arg ] unless arg.include?("*") || arg.include?("?")
      dir, pattern = File.split(arg)
      base = world.resolve(dir)
      return [ arg ] unless world.directory?(base)
      matches = world.children(base).map(&:first).select { |name| File.fnmatch(pattern, name) }
      matches.empty? ? [ arg ] : matches.map { |name| dir == "." && !arg.start_with?("./") ? name : File.join(dir, name) }
    end

    # --- result helpers -----------------------------------------------------

    def ok(text) = Result.new(output: text.to_s, exit_code: 0)
    def fail(text, code = 1) = Result.new(output: text.to_s, exit_code: code)
    def root? = world.session["user"] == "root"
    def host_name = world.current_host

    def writable?(path)
      @sudo || path.start_with?(world.home + "/") || path.start_with?("/tmp/")
    end

    def denied(cmd, path) = fail("#{cmd}: cannot open '#{path}': Permission denied\n(hint: system files need `sudo`)")

    def human(bytes)
      units = %w[B K M G T]
      value = bytes.to_f
      unit = 0
      while value >= 1024 && unit < units.size - 1
        value /= 1024
        unit += 1
      end
      return "#{bytes}" if unit.zero?
      value >= 10 ? "#{value.round}#{units[unit]}" : "#{format('%.1f', value)}#{units[unit]}"
    end

    def remember(flag)
      world.flags[flag] = world.clock
    end

    # --- redirection & filters ---------------------------------------------

    def write_redirect(result, redirect)
      path = world.resolve(redirect[:path])
      return denied("bash", path) unless writable?(path)
      return fail("bash: #{redirect[:path]}: Is a directory") if world.directory?(path)

      text = result.output.empty? ? "" : result.output + "\n"
      if redirect[:mode] == ">>" && world.file?(path)
        world.write_file(path, world.file(path)["content"].to_s + text)
      else
        world.write_file(path, text)
      end
      scenario.on_file_changed(world, path)
      Result.new(output: "", exit_code: result.exit_code)
    end

    def apply_filter(argv, text)
      name, *args = argv
      return fail("bash: #{name}: command not found", 127) unless FILTERS.include?(name)

      lines = text.lines.map(&:chomp)
      case name
      when "grep"
        invert = args.delete("-v")
        ignore = args.delete("-i")
        pattern = Regexp.new(Regexp.escape(args.first.to_s), ignore ? Regexp::IGNORECASE : nil)
        picked = lines.select { |l| invert ? l !~ pattern : l =~ pattern }
        Result.new(output: picked.join("\n"), exit_code: picked.empty? ? 1 : 0)
      when "head" then ok(lines.first(count_arg(args)).join("\n"))
      when "tail" then ok(lines.last(count_arg(args)).join("\n"))
      when "wc" then ok(lines.size.to_s)
      when "sort"
        sorted = args.any? { |a| a.include?("h") } ? lines.sort_by { |l| size_of(l.split.first) } : lines.sort
        sorted = sorted.reverse if args.any? { |a| a.include?("r") }
        ok(sorted.join("\n"))
      end
    end

    def count_arg(args)
      if (i = args.index("-n")) then args[i + 1].to_i
      elsif (flag = args.find { |a| a.match?(/\A-\d+\z/) }) then flag.delete("-").to_i
      else 10
      end
    end

    def size_of(text)
      m = text.to_s.match(/\A([\d.]+)([BKMGT]?)\z/) or return 0
      m[1].to_f * 1024**"BKMGT".index(m[2].presence || "B")
    end

    # --- basic commands -----------------------------------------------------

    def cmd_help(_args)
      ok(<<~TEXT.chomp)
        This is a simulated Linux shell. Commands you can try:
          ls, cd, pwd, cat, head, tail, grep, du, df, rm, truncate, echo, sed -i
          ssh, exit, whoami, hostname, uptime, free, ps, top, kill
          systemctl status|start|stop|restart <service>, journalctl -u <service>
          curl <url>, alerts, hint
        Pipes (|), && and > redirection work for simple cases. Use sudo for system files.
      TEXT
    end

    def cmd_hint(_args)
      ok(scenario.hint_for(world) || "No hints right now. Try `alerts` or check your objectives.")
    end

    def cmd_whoami(_args) = ok(world.session["user"])
    def cmd_hostname(_args) = ok(host_name)
    def cmd_pwd(_args) = ok(world.session["cwd"])
    def cmd_clear(_args) = ok("\e[2J\e[H")

    def cmd_echo(args) = ok(args.join(" "))

    def cmd_cd(args)
      target = world.resolve(args.first || "~")
      return fail("bash: cd: #{args.first}: No such file or directory") unless world.directory?(target)
      world.session["cwd"] = target
      ok("")
    end

    def cmd_ls(args)
      flags = args.select { |a| a.start_with?("-") }.join
      paths = args.reject { |a| a.start_with?("-") }
      paths = [ "." ] if paths.empty?
      long = flags.include?("l")
      human_sizes = flags.include?("h")

      blocks = paths.map do |raw|
        path = world.resolve(raw)
        entries =
          if world.file?(path) then [ [ File.basename(path), path, false ] ]
          elsif world.directory?(path) then world.children(path).reject { |name, _, _| name.start_with?(".") && !flags.include?("a") }
          else next "ls: cannot access '#{raw}': No such file or directory"
          end
        remember_listing(path)
        lines = entries.map do |name, full, dir|
          next(dir ? "#{name}/" : name) unless long
          size = dir ? 4096 : world.file(full)["size"]
          mode = dir ? "drwxr-xr-x" : world.file(full).fetch("mode", "-rw-r--r--")
          owner = dir ? "root" : world.file(full).fetch("owner", "root")
          format("%s 1 %-6s %-6s %6s %s %s", mode, owner, owner, human_sizes ? human(size) : size, world.timestamp[0, 12], name)
        end
        lines = [ "total #{entries.size * 4}" ] + lines if long
        paths.size > 1 ? "#{raw}:\n#{lines.join("\n")}" : lines.join(long ? "\n" : "  ")
      end
      ok(blocks.join("\n\n"))
    end

    def remember_listing(path)
      scenario.on_inspect(world, :ls, path)
    end

    def read_file(cmd, raw)
      path = world.resolve(raw)
      return [ nil, fail("#{cmd}: #{raw}: Is a directory") ] if world.directory?(path) && !world.file?(path)
      return [ nil, fail("#{cmd}: #{raw}: No such file or directory") ] unless world.file?(path)
      f = world.file(path)
      return [ nil, fail("#{cmd}: #{raw}: Permission denied") ] if f["secret"] && !@sudo
      scenario.on_inspect(world, :read, path)
      [ f, nil ]
    end

    def file_lines(f) = f["content"].to_s.lines.map(&:chomp)

    def cmd_cat(args)
      return fail("cat: missing file operand") if args.empty?
      failed = false
      outputs = args.map do |raw|
        f, error = read_file("cat", raw)
        next(failed = true) && error.output if error
        if f["size"] > 50 * World::MB
          "#{file_lines(f).last(8).join("\n")}\n... (#{human(f['size'])} file, showing the end. Try `tail` or `du -h`.)"
        else
          f["content"].to_s.chomp
        end
      end
      Result.new(output: outputs.join("\n"), exit_code: failed ? 1 : 0)
    end

    def cmd_head(args) = head_tail("head", args) { |lines, n| lines.first(n) }
    def cmd_tail(args) = head_tail("tail", args) { |lines, n| lines.last(n) }

    def head_tail(cmd, args)
      n = count_arg(args)
      files = args.reject { |a| a.start_with?("-") || a == n.to_s }
      return fail("#{cmd}: missing file operand") if files.empty?
      f, error = read_file(cmd, files.first)
      return error if error
      ok(yield(file_lines(f), n).join("\n"))
    end

    def cmd_grep(args)
      ignore = args.delete("-i")
      args.delete("-r")
      pattern, *paths = args
      return fail("usage: grep PATTERN FILE") if pattern.nil? || paths.empty?
      regex = Regexp.new(Regexp.escape(pattern), ignore ? Regexp::IGNORECASE : nil)
      matches = paths.flat_map do |raw|
        f, error = read_file("grep", raw)
        next [ error.output ] if error
        file_lines(f).grep(regex).map { |l| paths.size > 1 ? "#{raw}:#{l}" : l }
      end
      Result.new(output: matches.join("\n"), exit_code: matches.empty? ? 1 : 0)
    end

    def cmd_du(args)
      flags = args.select { |a| a.start_with?("-") }.join
      paths = args.reject { |a| a.start_with?("-") }
      paths = [ "." ] if paths.empty?
      summary = flags.include?("s")
      fmt = ->(bytes) { flags.include?("h") ? human(bytes) : (bytes / 1024).to_s }

      lines = paths.flat_map do |raw|
        path = world.resolve(raw)
        next [ "du: cannot access '#{raw}': No such file or directory" ] unless world.file?(path) || world.directory?(path)
        scenario.on_inspect(world, :du, path)
        if summary || world.file?(path)
          [ "#{fmt.(world.bytes_under(path))}\t#{raw}" ]
        else
          world.children(path).map { |name, full, _| "#{fmt.(world.bytes_under(full))}\t#{File.join(raw, name).delete_prefix('./')}" } +
            [ "#{fmt.(world.bytes_under(path))}\t#{raw}" ]
        end
      end
      ok(lines.join("\n"))
    end

    def cmd_df(args)
      scenario.on_inspect(world, :df, "/")
      h = args.any? { |a| a.include?("h") }
      d = world.disk
      size = h ? human(d["size"]) : d["size"] / 1024
      used = h ? human(world.disk_used) : world.disk_used / 1024
      avail_bytes = [ d["size"] - world.disk_used, 0 ].max
      avail = h ? human(avail_bytes) : avail_bytes / 1024
      ok([
        format("%-16s %6s %6s %6s %4s %s", "Filesystem", "Size", "Used", "Avail", "Use%", "Mounted on"),
        format("%-16s %6s %6s %6s %4s %s", d.fetch("device", "/dev/sda1"), size, used, avail, "#{world.disk_percent}%", "/"),
        format("%-16s %6s %6s %6s %4s %s", "tmpfs", h ? "2.0G" : 2_097_152, h ? "0" : 0, h ? "2.0G" : 2_097_152, "0%", "/dev/shm")
      ].join("\n"))
    end

    def cmd_rm(args)
      flags = args.select { |a| a.start_with?("-") }.join
      targets = args.reject { |a| a.start_with?("-") }
      return fail("rm: missing operand") if targets.empty?
      errors = targets.filter_map do |raw|
        path = world.resolve(raw)
        if world.directory?(path) && !world.file?(path)
          next "rm: cannot remove '#{raw}': Is a directory" unless flags.include?("r")
          next "rm: refusing to remove '#{raw}' in this simulator" if path.count("/") < 3
          next "rm: cannot remove '#{raw}': Permission denied" unless writable?(path)
          world.files.keys.select { |p| p.start_with?(path + "/") }.each { |p| world.delete_file(p) }
        elsif world.file?(path)
          next "rm: cannot remove '#{raw}': Permission denied" unless writable?(path)
          world.delete_file(path)
        else
          next(flags.include?("f") ? nil : "rm: cannot remove '#{raw}': No such file or directory")
        end
        scenario.on_file_changed(world, path)
        nil
      end
      errors.empty? ? ok("") : fail(errors.join("\n"))
    end

    def cmd_truncate(args)
      size_index = args.index("-s")
      return fail("usage: truncate -s 0 FILE") unless size_index && args[size_index + 1] == "0"
      targets = args.each_with_index.reject { |_, i| i == size_index || i == size_index + 1 }.map(&:first)
      targets.each do |raw|
        path = world.resolve(raw)
        return fail("truncate: cannot open '#{raw}' for writing: No such file or directory") unless world.file?(path)
        return fail("truncate: cannot open '#{raw}' for writing: Permission denied") unless writable?(path)
        world.write_file(path, "")
        scenario.on_file_changed(world, path)
      end
      ok("")
    end

    # Supports the one form beginners need: sed -i 's/old/new/' FILE
    def cmd_sed(args)
      in_place = args.delete("-i")
      expr, raw = args
      m = expr.to_s.match(%r{\As/((?:[^/\\]|\\.)*)/((?:[^/\\]|\\.)*)/(g?)\z})
      return fail("sed: only `sed -i 's/old/new/' FILE` is supported here") unless m && raw
      f, error = read_file("sed", raw)
      return error if error
      path = world.resolve(raw)
      pattern = begin
        Regexp.new(m[1], timeout: 0.2)
      rescue RegexpError
        Regexp.new(Regexp.escape(m[1]))
      end
      replacement = m[2].gsub("\\/", "/").gsub("\\n", "\n")
      updated = m[3] == "g" ? f["content"].gsub(pattern, replacement) : f["content"].lines.map { |l| l.sub(pattern, replacement) }.join
      return ok(updated.chomp) unless in_place
      return fail("sed: couldn't open temporary file #{File.dirname(path)}/sedXXXX: Permission denied") unless writable?(path)
      world.write_file(path, updated)
      scenario.on_file_changed(world, path)
      ok("")
    end

    # --- hosts --------------------------------------------------------------

    def cmd_ssh(args)
      target = args.reject { |a| a.start_with?("-") }.first
      return fail("usage: ssh [user@]host") unless target
      user, name = target.include?("@") ? target.split("@", 2) : [ nil, target ]
      unless world.host?(name) && world.host(name)["ssh"]
        return fail("ssh: Could not resolve hostname #{name}: Name or service not known", 255)
      end
      user ||= world.host(name)["ssh"]["user"]
      return fail("#{user}@#{name}: Permission denied (publickey).", 255) unless world.host(name)["ssh"]["user"] == user

      (world.session["stack"] ||= []) << world.session.slice("host", "user", "cwd")
      world.session.merge!("host" => name, "user" => user, "cwd" => "/home/#{user}")
      scenario.on_ssh(world, name)
      ok(world.host(name)["motd"].to_s)
    end

    def cmd_exit(_args)
      previous = (world.session["stack"] || []).pop
      return ok("logout (this is your own machine, there is nowhere to exit to)") unless previous
      leaving = host_name
      world.session.merge!(previous)
      ok("logout\nConnection to #{leaving} closed.")
    end
    alias cmd_logout cmd_exit

    def cmd_uptime(_args)
      load = world.host.fetch("load", [ 0.21, 0.18, 0.15 ]).map { |l| format("%.2f", l) }.join(", ")
      ok(" #{world.timestamp[7, 5]}:00 up 41 days,  3 users,  load average: #{load}")
    end

    # --- memory & processes ------------------------------------------------

    def cmd_free(args)
      scenario.on_inspect(world, :free, nil)
      total = world.host["memory_total_mb"]
      used = world.memory_used_mb.round
      free = [ total - used, 0 ].max
      h = args.any? { |a| a.include?("h") }
      fmt = ->(mb) { h ? (mb >= 1024 ? "#{format('%.1f', mb / 1024.0)}Gi" : "#{mb}Mi") : mb.to_s }
      ok([
        format("%-6s %10s %10s %10s %10s", "", "total", "used", "free", "available"),
        format("%-6s %10s %10s %10s %10s", "Mem:", fmt.(total), fmt.(used), fmt.(free), fmt.(free)),
        format("%-6s %10s %10s %10s %10s", "Swap:", fmt.(0), fmt.(0), fmt.(0), "")
      ].join("\n"))
    end

    def process_table(sorted_by_memory: false)
      total = world.host["memory_total_mb"].to_f
      procs = world.processes
      procs = procs.sort_by { |p| -p["mem_mb"].to_f } if sorted_by_memory
      rows = procs.map do |p|
        format("%-8s %6d %5.1f %5.1f %8d %s", p["user"], p["pid"], p.fetch("cpu", 0.3), p["mem_mb"] * 100 / total, (p["mem_mb"] * 1024).round, p["command"])
      end
      [ format("%-8s %6s %5s %5s %8s %s", "USER", "PID", "%CPU", "%MEM", "RSS", "COMMAND") ] + rows
    end

    def cmd_ps(args)
      sorted = args.any? { |a| a.include?("mem") }
      scenario.on_inspect(world, :ps, nil)
      ok(process_table(sorted_by_memory: sorted).join("\n"))
    end

    def cmd_top(_args)
      scenario.on_inspect(world, :ps, nil)
      header = [
        "top - #{world.timestamp[7, 5]}:00 up 41 days,  load average: #{world.host.fetch('load', [ 0.2 ]).first}",
        "MiB Mem : #{world.host['memory_total_mb']} total, #{world.memory_used_mb.round} used (#{world.memory_percent}%)",
        "(snapshot, sorted by memory; real top would keep refreshing)",
        ""
      ]
      ok((header + process_table(sorted_by_memory: true)).join("\n"))
    end

    def cmd_kill(args)
      signal = args.find { |a| a.start_with?("-") }
      pids = args.reject { |a| a.start_with?("-") }.map(&:to_i)
      return fail("kill: usage: kill [-9] pid") if pids.empty?
      pids.each do |pid|
        proc = world.processes.find { |p| p["pid"] == pid }
        return fail("kill: (#{pid}) - No such process") unless proc
        return fail("kill: (#{pid}) - Operation not permitted") unless @sudo || proc["user"] == world.session["user"]
        scenario.on_kill(world, proc, signal)
      end
      ok("")
    end

    # --- services -----------------------------------------------------------

    def cmd_systemctl(args)
      action, name = args.reject { |a| a.start_with?("-") }
      name = name.to_s.delete_suffix(".service")
      return ok(list_units) if action.nil? || action == "list-units"
      return fail("Unknown command verb #{action}.") unless %w[status start stop restart].include?(action)
      return fail("Too few arguments.") if name.empty?
      svc = world.service(name)
      return fail("Unit #{name}.service could not be found.", 4) unless svc

      if action == "status"
        scenario.on_inspect(world, :status, name)
        return Result.new(output: service_status(name, svc), exit_code: svc["state"] == "active" ? 0 : 3)
      end
      return fail("Failed to #{action} #{name}.service: Interactive authentication required.\n(hint: try `sudo systemctl #{action} #{name}`)") unless @sudo

      message = scenario.on_service(world, name, action)
      message ? fail(message) : ok("")
    end

    def list_units
      rows = world.services.map do |name, svc|
        format("%-24s loaded %-8s %-8s %s", "#{name}.service", svc["state"] == "active" ? "active" : "failed",
               svc["state"] == "active" ? "running" : "failed", svc["description"])
      end
      ([ format("%-24s %-6s %-8s %-8s %s", "UNIT", "LOAD", "ACTIVE", "SUB", "DESCRIPTION") ] + rows).join("\n")
    end

    def service_status(name, svc)
      dot = svc["state"] == "active" ? "●" : "×"
      active =
        if svc["state"] == "active" then "active (running) since #{world.timestamp(svc.fetch('started_at', 0))}"
        else "failed (Result: exit-code) since #{world.timestamp(svc.fetch('failed_at', 0))}"
        end
      mem = world.service_processes(name).sum { |p| p["mem_mb"] }
      lines = [
        "#{dot} #{name}.service - #{svc['description']}",
        "     Loaded: loaded (/etc/systemd/system/#{name}.service; enabled)",
        "     Active: #{active}"
      ]
      lines << "     Memory: #{mem.round}M" if svc["state"] == "active"
      lines << ""
      lines.concat(Array(svc["journal"]).last(5))
      lines.join("\n")
    end

    def cmd_journalctl(args)
      unit_index = args.index("-u")
      return fail("Specify a unit with -u, for example: journalctl -u shop-web") unless unit_index
      name = args[unit_index + 1].to_s.delete_suffix(".service")
      svc = world.service(name)
      return ok("-- No entries --") unless svc
      scenario.on_inspect(world, :journal, name)
      n = args.index("-n") ? args[args.index("-n") + 1].to_i : 20
      ok(Array(svc["journal"]).last(n).join("\n").presence || "-- No entries --")
    end

    # --- network ------------------------------------------------------------

    def cmd_curl(args)
      skip = args.each_index.select { |i| %w[-X -d -H --data --header --request].include?(args[i - 1]) && i.positive? }
      url = args.each_with_index.reject { |a, i| a.start_with?("-") || skip.include?(i) }.map(&:first).first
      return fail("curl: try 'curl https://shop.example/health'") unless url
      status, body = scenario.http(world, url)
      return fail("curl: (6) Could not resolve host: #{url}", 6) unless status
      verbose = args.any? { |a| %w[-i -I -v].include?(a) }
      ok(verbose ? "HTTP/1.1 #{status}\n\n#{body}" : body)
    end

    def cmd_alerts(args)
      scenario.on_inspect(world, :alerts, nil)
      if args.first == "ack"
        alert = world.alerts.find { |a| a["id"] == args[1] && a["state"] == "firing" }
        return fail("alerts: no firing alert with id #{args[1]}") unless alert
        alert["acknowledged"] = true
        return ok("Acknowledged #{alert['id']}. You own this incident now.")
      end
      return ok("No alerts. All quiet.") if world.alerts.empty?
      ok(world.alerts.map { |a|
        "[#{a['state'].upcase}] #{a['id']}  #{a['severity']}  #{a['summary']}#{'  (acked)' if a['acknowledged']}"
      }.join("\n"))
    end
  end
end
