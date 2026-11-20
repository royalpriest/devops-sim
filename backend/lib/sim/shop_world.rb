module Sim
  # The shared setting for the story: a small online shop ("shop.example")
  # running on one Linux server, web-01, that you reach from your laptop.
  module ShopWorld
    GB = World::GB
    MB = World::MB

    module_function

    def laptop
      {
        "linux_server" => false,
        "fs" => {
          "/home/dev/on-call.md" => text(<<~MD)
            # On-call cheat sheet
            - The shop runs on one server: web-01 (log in with `ssh web-01`)
            - Services: nginx (front door), shop-web (the Rails app), shop-worker (background jobs)
            - Health check: curl https://shop.example/health
            - Alerts: run `alerts` to see what's firing
          MD
        },
        "dirs" => [ "/home/dev", "/tmp" ],
        "services" => {},
        "processes" => [],
        "disk" => { "size" => 256 * GB, "base_used" => 90 * GB, "device" => "/dev/nvme0n1p2" },
        "memory_total_mb" => 16_384
      }
    end

    def web01(debug_log_size: 40 * MB, log_level: "info", cache_max: "500")
      {
        "linux_server" => true,
        "monitored" => true,
        "ssh" => { "user" => "deploy" },
        "motd" => "Welcome to Ubuntu 24.04 LTS (web-01)\n\n  This server runs shop.example. Be careful, it's production!\n",
        "fs" => {
          "/home/deploy/README.txt" => text("Deploys land in /srv/shop/current. Config lives in /etc/shop.\n"),
          "/etc/shop/web.env" => text("RAILS_ENV=production\nPORT=3000\nLOG_LEVEL=#{log_level}\n"),
          "/etc/shop/worker.env" => text("RAILS_ENV=production\nQUEUES=default,reports\nREPORT_CACHE_MAX=#{cache_max}\n"),
          "/srv/shop/current/REVISION" => text("41e2c9a\n"),
          "/srv/shop/current/config/puma.rb" => text("workers 2\nthreads 3, 5\nport ENV.fetch(\"PORT\", 3000)\n"),
          "/var/log/shop/production.log" => sized(180 * MB, production_log),
          "/var/log/shop/debug.log" => sized(debug_log_size, debug_log),
          "/var/log/nginx/access.log" => sized(350 * MB, access_log),
          "/var/log/nginx/error.log" => sized(2 * MB, ""),
          "/var/log/syslog" => sized(60 * MB, "Nov 20 08:59:01 web-01 CRON[2211]: (root) CMD (logrotate /etc/logrotate.conf)\n"),
          "/var/lib/postgresql/16/main/PG_VERSION" => sized(900 * MB, "16\n")
        },
        "dirs" => [ "/home/deploy", "/tmp", "/var/tmp", "/etc", "/srv/shop/releases" ],
        "disk" => { "size" => 20 * GB, "base_used" => (3.2 * GB).round, "device" => "/dev/vda1" },
        "memory_total_mb" => 4096,
        "services" => {
          "nginx" => service("nginx", "A high performance web server and a reverse proxy server", [
            process_spec("root", "nginx: master process /usr/sbin/nginx", 12),
            process_spec("www-data", "nginx: worker process", 18)
          ]),
          "shop-web" => service("shop-web", "Shop web app (puma)", [
            process_spec("deploy", "puma 6.4 (tcp://0.0.0.0:3000) [shop]", 310),
            process_spec("deploy", "puma: cluster worker 0 [shop]", 420),
            process_spec("deploy", "puma: cluster worker 1 [shop]", 410)
          ]),
          "shop-worker" => service("shop-worker", "Shop background jobs", [
            process_spec("deploy", "ruby bin/jobs --queues=default,reports [shop-worker]", 290)
          ]),
          "postgresql" => service("postgresql", "PostgreSQL 16 database server", [
            process_spec("postgres", "postgres: 16/main: checkpointer", 160)
          ])
        },
        "processes" => [
          { "pid" => 1, "user" => "root", "command" => "/sbin/init", "mem_mb" => 12 },
          { "pid" => 712, "user" => "root", "command" => "sshd: /usr/sbin/sshd -D", "mem_mb" => 8 },
          { "pid" => 845, "user" => "root", "command" => "/usr/bin/node_exporter", "mem_mb" => 22 }
        ],
        "next_pid" => 4100
      }
    end

    def service(name, description, spawn)
      { "state" => "inactive", "description" => description, "spawn" => spawn, "journal" => [], "unit_name" => name }
    end

    def process_spec(user, command, mem_mb) = { "user" => user, "command" => command, "mem_mb" => mem_mb, "cpu" => 1.2 }

    def text(content) = { "content" => content, "size" => content.bytesize, "mode" => "-rw-r--r--", "owner" => "root" }
    def sized(size, content) = text(content).merge("size" => size)

    def production_log
      <<~LOG
        I, [2026-11-20T08:58:12] INFO -- : Started GET "/products/42" for 203.0.113.9
        I, [2026-11-20T08:58:12] INFO -- : Completed 200 OK in 38ms
        I, [2026-11-20T08:58:40] INFO -- : Started POST "/cart" for 198.51.100.4
        I, [2026-11-20T08:58:40] INFO -- : Completed 302 Found in 21ms
      LOG
    end

    def debug_log
      <<~LOG
        D, [2026-11-20T08:59:58] DEBUG -- : SQL (0.4ms) SELECT "products".* FROM "products" WHERE "id" = 42
        D, [2026-11-20T08:59:58] DEBUG -- : Rendered products/show.html.erb (12.1ms)
        D, [2026-11-20T08:59:59] DEBUG -- : SQL (0.3ms) SELECT "carts".* FROM "carts" WHERE "id" = 991
        D, [2026-11-20T08:59:59] DEBUG -- : Cache read: views/products/42-20261120 (0.1ms)
      LOG
    end

    def access_log
      <<~LOG
        203.0.113.9 - - [20/Nov/2026:08:58:12] "GET /products/42 HTTP/1.1" 200 5123
        198.51.100.4 - - [20/Nov/2026:08:58:40] "POST /cart HTTP/1.1" 302 0
      LOG
    end

    # Boot the services that should be running at the start of a chapter.
    def boot(scenario, world, *names, host: "web-01")
      names.each { |name| scenario.start_service(world, name, host: host) }
    end

    MAP_NODES = [
      { "id" => "laptop", "label" => "Your laptop", "kind" => "dev", "inspect" => "cat ~/on-call.md" },
      { "id" => "nginx", "label" => "nginx", "kind" => "front door", "service" => "nginx" },
      { "id" => "shop-web", "label" => "shop-web", "kind" => "Rails app", "service" => "shop-web" },
      { "id" => "shop-worker", "label" => "shop-worker", "kind" => "background jobs", "service" => "shop-worker" },
      { "id" => "postgresql", "label" => "postgresql", "kind" => "database", "service" => "postgresql" },
      { "id" => "disk", "label" => "Disk /", "kind" => "storage", "inspect" => "df -h" }
    ].freeze
    MAP_EDGES = [ %w[laptop nginx], %w[nginx shop-web], %w[shop-web postgresql], %w[shop-worker postgresql],
                  %w[shop-web shop-worker], %w[shop-web disk] ].freeze

    # What the play screen draws: the shop's parts, how they connect, and
    # which one is in trouble right now. Status comes straight from the world.
    def map(world)
      nodes = MAP_NODES.map do |node|
        node.merge(map_status(world, node)).merge("host" => node["id"] == "laptop" ? "laptop" : "web-01")
      end
      { "nodes" => nodes, "edges" => MAP_EDGES }
    end

    def map_status(world, node)
      if node["id"] == "laptop"
        on_server = world.current_host == "web-01"
        return { "status" => "ok", "detail" => on_server ? "connected over ssh" : "you are here" }
      end
      if node["id"] == "disk"
        pct = world.disk_percent("web-01")
        return { "status" => pct >= 90 ? "bad" : pct >= 80 ? "warn" : "ok", "detail" => "#{pct}% used", "level" => pct }
      end

      svc = world.service(node["service"], "web-01")
      mem = world.service_processes(node["service"], "web-01").sum { |p| p["mem_mb"] }.round
      level = (mem * 100.0 / world.host("web-01")["memory_total_mb"]).round
      status, detail =
        if svc["state"] != "active" then [ "bad", svc["state"] == "failed" ? "crashed" : "stopped" ]
        elsif level >= 40 then [ "warn", "#{format_mb(mem)} · high memory" ]
        else [ "ok", "running · #{format_mb(mem)}" ]
        end
      { "status" => status, "detail" => detail, "level" => level, "inspect" => "systemctl status #{node['service']}" }
    end

    def format_mb(mb) = mb >= 1024 ? "#{format('%.2f', mb / 1024.0)} GB" : "#{mb} MB"

    # Recent journal lines per service, for the Logs tab.
    def logs(world)
      world.services("web-01").to_h { |name, svc| [ name, Array(svc["journal"]).last(40) ] }
    end

    # Shared HTTP behaviour: the site is up when nginx and shop-web are running.
    def http(world, url)
      return nil unless url.match?(%r{\A(https?://)?(shop\.example|localhost|127\.0\.0\.1|web-01)(:\d+)?(/.*)?\z})
      up = world.service("nginx", "web-01")["state"] == "active" && world.service("shop-web", "web-01")["state"] == "active"
      world.flags["last_curl_ok"] = up ? world.clock : nil
      if !up
        [ "502 Bad Gateway", "<html><head><title>502 Bad Gateway</title></head><body><center><h1>502 Bad Gateway</h1></center><hr><center>nginx</center></body></html>" ]
      elsif url.include?("/health")
        [ "200 OK", "{\"status\":\"ok\",\"revision\":\"41e2c9a\"}" ]
      else
        [ "200 OK", "<html><body><h1>Ruby Shop</h1><p>Today's deals...</p></body></html>" ]
      end
    end
  end
end
