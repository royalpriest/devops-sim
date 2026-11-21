module Sim
  # The whole simulated environment for one run, kept as a plain Hash with
  # string keys so it round-trips through the JSON column unchanged.
  #
  #   hosts:    name => { fs, services, processes, disk, memory_total_mb, env }
  #   session:  where the player is (host, user, cwd) and the ssh stack
  #   alerts:   monitoring alerts (firing / resolved)
  #   metrics:  time series per host, one point per tick
  #   history:  every command the player typed, with the host it ran on
  #   flags:    scenario-specific facts ("found_big_log" etc.)
  #   fired:    ids of scheduled events that already happened
  class World
    GB = 1024**3
    MB = 1024**2

    attr_reader :data

    def initialize(data)
      @data = data
    end

    def to_h = data

    def host(name = current_host) = data["hosts"].fetch(name)
    def host?(name) = data["hosts"].key?(name)
    def session = data["session"]
    def current_host = session["host"]
    def flags = data["flags"]
    def history = data["history"]
    def alerts = data["alerts"]
    def fired = data["fired"]

    # --- files --------------------------------------------------------------

    def files(host_name = current_host) = host(host_name)["fs"]
    def file(path, host_name = current_host) = files(host_name)[path]
    def file?(path, host_name = current_host) = files(host_name).key?(path)

    def directory?(path, host_name = current_host)
      return true if path == "/"
      prefix = path.chomp("/") + "/"
      files(host_name).keys.any? { |p| p.start_with?(prefix) } ||
        host(host_name).fetch("dirs", []).include?(path)
    end

    def write_file(path, content, host_name = current_host)
      entry = files(host_name)[path] ||= { "mode" => "-rw-r--r--", "owner" => "root" }
      entry["content"] = content
      entry["size"] = content.bytesize
      entry
    end

    # Append a log line without resetting the file's (possibly huge) size.
    def append_line(path, line, host_name = current_host)
      f = file(path, host_name) or return
      f["content"] = f["content"].to_s + line + "\n"
      f["size"] += line.bytesize + 1
    end

    def delete_file(path, host_name = current_host)
      files(host_name).delete(path)
    end

    # Immediate children of a directory: [[name, path, directory?], ...]
    def children(dir, host_name = current_host)
      prefix = dir == "/" ? "/" : dir.chomp("/") + "/"
      names = {}
      files(host_name).each_key do |p|
        next unless p.start_with?(prefix)
        rest = p.delete_prefix(prefix)
        first, more = rest.split("/", 2)
        names[first] ||= more ? :dir : :file
      end
      host(host_name).fetch("dirs", []).each do |d|
        next unless d.start_with?(prefix) && d != dir
        first, more = d.delete_prefix(prefix).split("/", 2)
        names[first] ||= :dir
        names[first] = :dir if more
      end
      names.sort.map { |name, kind| [ name, prefix + name, kind == :dir ] }
    end

    def bytes_under(path, host_name = current_host)
      return file(path, host_name)["size"] if file?(path, host_name)
      prefix = path == "/" ? "/" : path.chomp("/") + "/"
      files(host_name).sum { |p, f| p.start_with?(prefix) ? f["size"].to_i : 0 }
    end

    # --- disk ---------------------------------------------------------------

    def disk(host_name = current_host) = host(host_name)["disk"]

    def disk_used(host_name = current_host)
      disk(host_name)["base_used"] + bytes_under("/", host_name)
    end

    def disk_percent(host_name = current_host)
      [ (disk_used(host_name) * 100.0 / disk(host_name)["size"]).round, 100 ].min
    end

    def disk_full?(host_name = current_host) = disk_used(host_name) >= disk(host_name)["size"]

    # Grow a file, but never past the end of the disk (like a real full disk).
    def grow_file(path, bytes, host_name = current_host)
      f = file(path, host_name) or return
      room = disk(host_name)["size"] - disk_used(host_name)
      f["size"] += [ bytes, room ].min.clamp(0, bytes)
    end

    # --- services & processes ----------------------------------------------

    def services(host_name = current_host) = host(host_name)["services"]
    def service(name, host_name = current_host) = services(host_name)[name]
    def processes(host_name = current_host) = host(host_name)["processes"]

    def service_processes(name, host_name = current_host)
      processes(host_name).select { |p| p["service"] == name }
    end

    def journal(name, line, host_name = current_host)
      svc = service(name, host_name) or return
      (svc["journal"] ||= []) << "#{timestamp} #{host_name} #{svc.fetch('unit_name', name)}[#{svc['pid'] || 1}]: #{line}"
    end

    def memory_used_mb(host_name = current_host)
      processes(host_name).sum { |p| p["mem_mb"].to_f }
    end

    def memory_percent(host_name = current_host)
      (memory_used_mb(host_name) * 100.0 / host(host_name)["memory_total_mb"]).round
    end

    def next_pid(host_name = current_host)
      host(host_name)["next_pid"] = host(host_name).fetch("next_pid", 4000) + 1
    end

    # --- env files (KEY=value) ---------------------------------------------

    def env_value(path, key, host_name = current_host)
      f = file(path, host_name) or return
      f["content"].each_line do |line|
        k, v = line.strip.split("=", 2)
        return v if k == key
      end
      nil
    end

    # --- alerts -------------------------------------------------------------

    def fire_alert(id, attrs)
      return if alerts.any? { |a| a["id"] == id && a["state"] == "firing" }
      alerts << attrs.merge("id" => id, "state" => "firing", "fired_at" => clock, "acknowledged" => false)
    end

    def resolve_alert(id)
      alerts.each { |a| a["state"] = "resolved" if a["id"] == id && a["state"] == "firing" }
    end

    def firing_alerts = alerts.select { |a| a["state"] == "firing" }

    # --- time ---------------------------------------------------------------

    def clock = data["clock"]
    def clock=(value)
      data["clock"] = value
    end

    # The fake wall clock: 09:00 plus one minute per tick, so logs read naturally.
    def timestamp(tick = clock)
      minutes = 9 * 60 + tick
      format("Nov 20 %02d:%02d:%02d", minutes / 60 % 24, minutes % 60, (tick * 7) % 60)
    end

    def record_metrics
      data["metrics"] ||= {}
      data["hosts"].each_key do |name|
        next unless host(name)["monitored"]
        series = (data["metrics"][name] ||= [])
        series << { "t" => clock, "memory" => memory_percent(name), "disk" => disk_percent(name),
                    "cpu" => host(name).fetch("cpu_percent", 12), "errors" => host(name).fetch("error_rate", 0) }
        series.shift while series.size > 120
      end
    end

    # --- paths --------------------------------------------------------------

    def home = session["user"] == "root" ? "/root" : "/home/#{session['user']}"

    def resolve(path)
      path = path.to_s
      path = home + path.delete_prefix("~") if path.start_with?("~")
      path = File.join(session["cwd"], path) unless path.start_with?("/")
      parts = []
      path.split("/").each do |part|
        case part
        when "", "." then next
        when ".." then parts.pop
        else parts << part
        end
      end
      "/" + parts.join("/")
    end
  end
end
