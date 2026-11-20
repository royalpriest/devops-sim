module Sim
  module Scenarios
    # Chapter: a memory alert fires. The background worker's memory keeps
    # climbing because the last deploy set its report cache to unlimited.
    # Restarting alone only buys time; the real fix is the config.
    class MonitoringMemoryLeak < Scenario
      self.key = "monitoring-memory-leak"
      self.chapter = 5
      self.topic = "Monitoring"
      self.title = "Memory is climbing"
      self.summary = "A memory alert fires. Use the dashboard and the server to trace the cause and fix it for good."
      self.focus_metric = "memory"
      self.briefing = <<~TEXT
        It's a quiet afternoon. The site is up and the dashboard looks calm.
        Keep an eye on the memory graph for web-01. Monitoring will page you
        if something goes wrong. (Type `alerts` at any time.)
      TEXT

      WEB = "web-01"
      WORKER = "shop-worker"
      LEAK_PER_TICK = 170
      # Once paged, the leak slows down so a beginner has time to investigate
      # before the kernel starts killing processes.
      LEAK_AFTER_ALERT = 40
      LEAK_STARTS_AT = 1
      HEAD_START_MB = 600
      ALERT_AT = 85
      RECOVERED_BELOW = 70
      OOM_AT = 98

      def build_world
        data = empty_world
        data["hosts"]["laptop"] = ShopWorld.laptop
        data["hosts"][WEB] = ShopWorld.web01(cache_max: "0  # 0 = unlimited (changed in 41e2c9a for big exports)")
        data["session"] = { "host" => "laptop", "user" => "dev", "cwd" => "/home/dev" }
        world = World.new(data)
        ShopWorld.boot(self, world, "postgresql", "nginx", "shop-web", WORKER)
        # The leak has been going for a while before the player arrives, so
        # the alert fires within a minute or so of real time.
        world.service_processes(WORKER, WEB).first["mem_mb"] += HEAD_START_MB
        data
      end

      def objectives
        [
          Objective.new(id: "see-alert", title: "Look at the alert that just fired",
            hint: "Wait for the memory graph to climb, then run `alerts`.",
            check: ->(w) { (t = alert_fired_at(w)) && inspected?(w, :alerts, since: t) }),
          Objective.new(id: "connect", title: "Log in to web-01",
            hint: "The alert is about web-01. Run `ssh web-01`.",
            check: ->(w) { w.current_host == WEB || w.flags.key?("visited_#{WEB}") }),
          Objective.new(id: "find-process", title: "Find the process using the memory",
            hint: "`free -h` shows total memory. `ps aux --sort=-%mem` or `top` shows which process is using it.",
            check: ->(w) { w.history.any? { |h| h["host"] == WEB && Array(h["inspected"]).any? { |k, _| k == "ps" } } }),
          Objective.new(id: "trace-cause", title: "Trace the cause in the worker's logs or config",
            hint: "It's the shop-worker. Read its logs with `journalctl -u shop-worker`, and its config in /etc/shop/worker.env.",
            check: ->(w) { inspected?(w, :journal, WORKER) || inspected?(w, :read, "/etc/shop/worker.env") }),
          Objective.new(id: "fix-config", title: "Give the report cache a limit",
            hint: "Set a real limit, for example: `sudo sed -i 's/REPORT_CACHE_MAX=0.*/REPORT_CACHE_MAX=500/' /etc/shop/worker.env`.",
            check: ->(w) { cache_limit(w).positive? }),
          Objective.new(id: "recover", title: "Restart the worker and watch memory recover",
            hint: "`sudo systemctl restart shop-worker`, then watch the graph drop and the alert resolve.",
            check: lambda { |w|
              w.service(WORKER, WEB)["state"] == "active" && w.service(WORKER, WEB)["loaded_cache_max"].to_i.positive? &&
                w.memory_percent(WEB) < RECOVERED_BELOW && w.firing_alerts.none? { |a| a["id"] == "HighMemoryUsage" }
            })
        ]
      end

      def on_ssh(world, host)
        world.flags["visited_#{host}"] ||= world.clock
      end

      def after_start(world, name, host)
        return unless name == WORKER
        world.service(name, host)["loaded_cache_max"] = cache_limit(world)
        world.service(name, host)["cache_entries"] = 0
      end

      def tick(world)
        leak(world) if world.clock >= LEAK_STARTS_AT
        percent = world.memory_percent(WEB)

        if percent >= ALERT_AT && world.firing_alerts.none? { |a| a["id"] == "HighMemoryUsage" }
          world.fire_alert("HighMemoryUsage", "severity" => "warning", "host" => WEB,
                           "summary" => "web-01 memory usage is #{percent}% (threshold #{ALERT_AT}%)")
          world.flags["alert_fired_at"] ||= world.clock
          world.data["messages"] << { "kind" => "alert", "text" => "[ALERT] HighMemoryUsage on web-01: memory at #{percent}%. Run `alerts` for details." }
        elsif percent < RECOVERED_BELOW && world.firing_alerts.any? { |a| a["id"] == "HighMemoryUsage" }
          world.resolve_alert("HighMemoryUsage")
          world.data["messages"] << { "kind" => "resolved", "text" => "[RESOLVED] HighMemoryUsage on web-01: memory back to #{percent}%." }
        end

        oom_kill(world) if percent >= OOM_AT
      end

      def http(world, url) = ShopWorld.http(world, url)

      private

      def alert_fired_at(world) = world.flags["alert_fired_at"]

      def cache_limit(world)
        world.env_value("/etc/shop/worker.env", "REPORT_CACHE_MAX", WEB).to_s[/\A\s*(\d+)/, 1].to_i
      end

      def leak(world)
        svc = world.service(WORKER, WEB)
        return unless svc["state"] == "active" && svc["loaded_cache_max"].to_i.zero?
        worker = world.service_processes(WORKER, WEB).first or return
        worker["mem_mb"] += world.flags["alert_fired_at"] ? LEAK_AFTER_ALERT : LEAK_PER_TICK
        worker["cpu"] = 38.0
        svc["cache_entries"] = svc["cache_entries"].to_i + 6_000 + world.clock * 37
        world.journal(WORKER, "ReportExportJob: report cache now #{svc['cache_entries']} entries (limit: none, REPORT_CACHE_MAX=0)", WEB)
      end

      # The kernel picks the biggest process and kills it; systemd restarts the
      # worker, which starts leaking again from scratch.
      def oom_kill(world)
        victim = world.processes(WEB).max_by { |p| p["mem_mb"] }
        world.processes(WEB).delete(victim)
        world.append_line("/var/log/syslog", "#{world.timestamp} web-01 kernel: Out of memory: Killed process #{victim['pid']} (#{victim['command']})", WEB)
        world.data["messages"] << { "kind" => "alert", "text" => "[ALERT] web-01 ran out of memory. The kernel killed PID #{victim['pid']} (#{victim['command']})." }
        return unless victim["service"]
        world.journal(victim["service"], "#{victim['service']}.service: A process of this unit has been killed by the OOM killer.", WEB)
        world.journal(victim["service"], "#{victim['service']}.service: Scheduled restart job, restart counter is at #{world.clock}.", WEB)
        stop_service(world, victim["service"], host: WEB)
        start_service(world, victim["service"], host: WEB)
      end
    end
  end
end
