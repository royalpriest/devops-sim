module Sim
  module Scenarios
    # Chapter: the site is down because the disk filled up, and the app
    # crashed trying to write its logs. The fix has to stick: if debug
    # logging stays on, the disk fills up again a few minutes later.
    class LinuxDiskFull < Scenario
      self.key = "linux-disk-full"
      self.chapter = 4
      self.topic = "Linux"
      self.title = "The disk is full"
      self.summary = "SSH into the server, find what filled the disk, and bring the crashed app back."
      self.briefing = <<~TEXT
        Your phone buzzes: "shop.example is showing 502 errors!"
        You're on call. The shop runs on a server called web-01.
        Read ~/on-call.md if you need a reminder, then go and fix it.
      TEXT

      DEBUG_GROWTH = (1.5 * World::GB).round
      WEB = "web-01"

      def build_world
        data = empty_world
        data["hosts"]["laptop"] = ShopWorld.laptop
        data["hosts"][WEB] = ShopWorld.web01(debug_log_size: 0, log_level: "debug")
        data["session"] = { "host" => "laptop", "user" => "dev", "cwd" => "/home/dev" }
        world = World.new(data)

        ShopWorld.boot(self, world, "postgresql", "nginx", "shop-worker", "shop-web")
        fill_disk(world)
        crash_web(world, at: 0)

        world.fire_alert("SiteDown", "severity" => "critical", "summary" => "https://shop.example/health is returning 502")
        data
      end

      def objectives
        [
          Objective.new(id: "connect", title: "Log in to web-01 over SSH",
            hint: "Your laptop can't see the server's services. Run `ssh web-01`.",
            check: ->(w) { w.flags.key?("visited_#{WEB}") }),
          Objective.new(id: "diagnose", title: "Find out why shop-web stopped",
            hint: "Ask systemd: `systemctl status shop-web`, then read more with `journalctl -u shop-web`.",
            check: ->(w) { inspected?(w, :status, "shop-web") || inspected?(w, :journal, "shop-web") }),
          Objective.new(id: "find-culprit", title: "Find what is filling the disk",
            hint: "`df -h` shows how full the disk is. `du -sh /var/log/*` shows which folder is big. Keep drilling in.",
            check: ->(w) { inspected?(w, :du, "/var/log/shop") || inspected?(w, :ls, "/var/log/shop") }),
          Objective.new(id: "free-space", title: "Free up disk space (get below 80%)",
            hint: "That debug.log is huge. `sudo truncate -s 0 /var/log/shop/debug.log` empties it (or `sudo rm` it).",
            check: ->(w) { w.disk_percent(WEB) < 80 }),
          Objective.new(id: "stop-debug", title: "Turn off debug logging so it doesn't refill",
            hint: "The log level is set in /etc/shop/web.env. Try `sudo sed -i 's/LOG_LEVEL=debug/LOG_LEVEL=info/' /etc/shop/web.env`.",
            check: ->(w) { w.env_value("/etc/shop/web.env", "LOG_LEVEL", WEB) != "debug" }),
          Objective.new(id: "recover", title: "Restart shop-web and check the site is back",
            hint: "Config is read at startup: `sudo systemctl restart shop-web`, then `curl https://shop.example/health`.",
            check: lambda { |w|
              svc = w.service("shop-web", WEB)
              svc["state"] == "active" && svc["loaded_log_level"] != "debug" &&
                w.flags["last_curl_ok"].to_i >= svc["started_at"].to_i
            })
        ]
      end

      def on_ssh(world, host)
        world.flags["visited_#{host}"] ||= world.clock
      end

      def after_start(world, name, host)
        return unless name == "shop-web"
        world.service(name, host)["loaded_log_level"] = world.env_value("/etc/shop/web.env", "LOG_LEVEL", WEB)
      end

      def start_blocker(world, name)
        return unless name == "shop-web" && world.disk_full?(WEB)
        "Errno::ENOSPC: No space left on device @ rb_sysopen - /srv/shop/current/tmp/pids/server.pid"
      end

      def tick(world)
        web = world.service("shop-web", WEB)
        if web["state"] == "active" && web["loaded_log_level"] == "debug"
          world.grow_file("/var/log/shop/debug.log", DEBUG_GROWTH, WEB)
          if world.disk_full?(WEB)
            crash_web(world, at: world.clock)
            world.data["messages"] << { "kind" => "alert", "text" => "[ALERT] SiteDown: shop-web crashed again. The disk filled back up." }
          end
        end

        if web["state"] == "active" && world.alerts.any? { |a| a["id"] == "SiteDown" && a["state"] == "firing" }
          world.resolve_alert("SiteDown")
          world.data["messages"] << { "kind" => "resolved", "text" => "[RESOLVED] SiteDown: shop.example is answering again." }
        elsif web["state"] != "active"
          world.fire_alert("SiteDown", "severity" => "critical", "summary" => "https://shop.example/health is returning 502")
        end
      end

      def http(world, url) = ShopWorld.http(world, url)

      private

      def fill_disk(world)
        room = world.disk(WEB)["size"] - world.disk_used(WEB)
        world.grow_file("/var/log/shop/debug.log", room, WEB)
      end

      def crash_web(world, at:)
        world.processes(WEB).reject! { |p| p["service"] == "shop-web" }
        svc = world.service("shop-web", WEB)
        svc["state"] = "failed"
        svc["failed_at"] = at
        world.journal("shop-web", "Errno::ENOSPC: No space left on device @ io_write - /var/log/shop/debug.log", WEB)
        world.journal("shop-web", "puma: shutting down after unhandled error", WEB)
        world.journal("shop-web", "shop-web.service: Main process exited, code=exited, status=1/FAILURE", WEB)
        world.journal("shop-web", "shop-web.service: Failed with result 'exit-code'.", WEB)
      end
    end
  end
end
