module Sim
  module Scenarios
    # Chapter: a config change breaks checkout. The health check still says
    # OK, so only the error alert and the logs tell the truth. Roll back first,
    # then revert the commit so the next deploy doesn't ship it again.
    class DeployRollback < Scenario
      self.key = "deploy-rollback"
      self.chapter = 3
      self.topic = "Deploy"
      self.title = "The health check is lying"
      self.summary = "A release breaks checkout while the health check stays green. Roll it back, then stop it coming back."
      self.focus_metric = "errors"
      self.briefing = <<~TEXT
        Release r43 went out ten minutes ago: "Switch checkout to payments v2".
        The deploy finished, the health check is green... and then your phone buzzes.
        The deploy tool works from your laptop: try `deploy` to see what it can do.
      TEXT
      self.real_world = {
        "text" => "Config changes cause a surprising share of big outages. In August 2024 a database config change took GitHub's read path down for 36 minutes until it was reverted. In December 2025 a config change rolled out to all of Cloudflare at once and caused HTTP 500 errors. The usual first move is the same as yours: roll back first, investigate after.",
        "source_title" => "Dan Luu's collection of post-mortems",
        "source_url" => "https://github.com/danluu/post-mortems"
      }

      GOOD = "r42".freeze
      BAD = "r43".freeze

      def build_world
        data = empty_world
        data["hosts"]["laptop"] = ShopWorld.laptop
        data["hosts"]["web-01"] = ShopWorld.web01.merge("error_rate" => 38)
        data["session"] = { "host" => "laptop", "user" => "dev", "cwd" => DeliveryWorld::ROOT }
        repo = DeliveryWorld.add_repo(data, history: [
          [ "Add cart tests", DeliveryWorld.base_files ],
          [ "Show free shipping banner", DeliveryWorld.base_files.merge(DeliveryWorld::BANNER_FILE) ],
          [ "Switch checkout to payments v2", DeliveryWorld.base_files(payments: DeliveryWorld::PAYMENTS_V2).merge(DeliveryWorld::BANNER_FILE), "alex" ]
        ])
        shas = Repo.new(World.new(data)).log.map(&:first).reverse
        data["deploy"] = {
          "current" => BAD,
          "releases" => [
            { "id" => "r41", "sha" => shas[0], "message" => "Add cart tests", "by" => "sam", "at" => -300 },
            { "id" => GOOD, "sha" => shas[1], "message" => "Show free shipping banner", "by" => "you", "at" => -120 },
            { "id" => BAD, "sha" => shas[2], "message" => "Switch checkout to payments v2", "by" => "alex", "at" => -10 }
          ],
          "logs" => bad_logs(-9)
        }
        world = World.new(data)
        ShopWorld.boot(self, world, "postgresql", "nginx", "shop-web", "shop-worker")
        world.fire_alert("CheckoutErrors", "severity" => "critical", "summary" => "38% of POST /checkout requests return 500")
        data
      end

      def bad_logs(at)
        (0..5).flat_map do |i|
          t = format("09:%02d:%02d", (at + 10 + i) % 60, (i * 13) % 60)
          [ "#{t} Started POST \"/checkout\" for 203.0.113.#{20 + i}",
            "#{t} PaymentsClient::NotFound (404 from https://payments.internal/v2/charge):",
            "#{t}   app/services/charge_card.rb:18:in 'call'",
            "#{t} Completed 500 Internal Server Error in 31ms" ]
        end + [ "09:00:59 Started GET \"/health\" for 10.0.0.5", "09:00:59 Completed 200 OK in 2ms" ]
      end

      def objectives
        [
          Objective.new(id: "symptom", title: "Check what shoppers are seeing",
            hint: "Try the health check and the checkout: `curl -i https://shop.example/health` then `curl -i -X POST https://shop.example/checkout`.",
            check: ->(w) { w.flags.key?("saw_checkout_500") }),
          Objective.new(id: "changes", title: "See what was deployed recently",
            hint: "`deploy releases` lists what went out and when.",
            check: ->(w) { inspected?(w, :deploy, "releases") || inspected?(w, :deploy, "history") || inspected?(w, :deploy, "status") }),
          Objective.new(id: "logs", title: "Find the error in the production logs",
            hint: "`deploy logs` shows the last lines from production. What's failing?",
            check: ->(w) { inspected?(w, :deploy, "logs") }),
          Objective.new(id: "rollback", title: "Roll back to the last good release",
            hint: "Put #{GOOD} back: `deploy rollback #{GOOD}`.",
            check: ->(w) { w.data["deploy"]["current"] != BAD }),
          Objective.new(id: "verify", title: "Confirm checkout works again",
            hint: "`curl -i -X POST https://shop.example/checkout` should say 200 now.",
            check: ->(w) { w.flags["checkout_ok_at"].to_i >= w.flags["rolled_back_at"].to_i && w.flags.key?("rolled_back_at") }),
          Objective.new(id: "revert", title: "Revert the bad commit on main so it can't ship again",
            hint: "`git log --oneline` to find the commit, `git revert <sha>`, then `git push`.",
            check: lambda { |w|
              repo = Repo.new(w)
              repo.snapshot(w.data["repo"]["remote"]["main"])["config/payments.yml"] == DeliveryWorld::PAYMENTS_V1
            })
        ]
      end

      def on_rollback(world, release)
        good = release["id"] != BAD
        world.host("web-01")["error_rate"] = good ? 0 : 38
        world.flags["rolled_back_at"] = world.clock if good
        d = world.data["deploy"]
        d["logs"] = good ? [ "09:#{format('%02d', world.clock % 60)}:00 Booted #{release['id']} (#{release['sha']})",
                            "09:#{format('%02d', world.clock % 60)}:04 Started POST \"/checkout\" for 203.0.113.40",
                            "09:#{format('%02d', world.clock % 60)}:04 Completed 302 Found in 48ms" ] : bad_logs(world.clock)
      end

      def tick(world)
        DeliveryCi.advance(world, self)
        broken = world.data["deploy"]["current"] == BAD
        if !broken && world.firing_alerts.any? { |a| a["id"] == "CheckoutErrors" }
          world.resolve_alert("CheckoutErrors")
          world.data["messages"] << { "kind" => "resolved", "text" => "[RESOLVED] CheckoutErrors: checkout error rate is back to 0%." }
        end
      end

      def http(world, url)
        return nil unless url.match?(%r{\A(https?://)?shop\.example(/.*)?\z})
        broken = world.data["deploy"]["current"] == BAD
        if url.include?("/checkout")
          if broken
            world.flags["saw_checkout_500"] ||= world.clock
            [ "500 Internal Server Error", "We're sorry, but something went wrong." ]
          else
            world.flags["checkout_ok_at"] = world.clock
            [ "200 OK", "{\"order\":\"#{4200 + world.clock}\",\"status\":\"paid\"}" ]
          end
        elsif url.include?("/health")
          [ "200 OK", "{\"status\":\"ok\",\"release\":\"#{world.data['deploy']['current']}\"}" ]
        else
          [ "200 OK", "<html><body><h1>Ruby Shop</h1><p>Free shipping on orders over $50</p></body></html>" ]
        end
      end

      def map(world) = DeliveryWorld.map(world, production: true)
      def logs(world) = { "production" => world.data["deploy"]["logs"] }
    end
  end
end
