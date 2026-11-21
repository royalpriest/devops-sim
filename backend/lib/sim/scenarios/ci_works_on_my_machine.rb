module Sim
  module Scenarios
    # Chapter: tests pass on your laptop and fail in CI. Your local .env sets
    # a value the code depends on; CI is a clean machine that doesn't have it.
    class CiWorksOnMyMachine < Scenario
      self.key = "ci-works-on-my-machine"
      self.chapter = 2
      self.topic = "CI"
      self.title = "Works on my machine"
      self.summary = "Your tests pass locally but CI is red. Read the logs and find out what's different."
      self.focus_metric = nil
      self.briefing = <<~TEXT
        Yesterday you opened PR #14, "Make free-shipping threshold configurable".
        Your teammate pings you: "CI is red on your PR, can you take a look?"
        You're in ~/shop on the feature branch. The tests passed on your laptop...
      TEXT
      self.real_world = {
        "text" => "\"Passes locally, fails in CI\" is one of the most common CI problems. A frequent cause is an environment variable or secret that exists on your machine but not on the CI runner. CI starts from a clean machine on every run, and that's exactly why it's useful.",
        "source_title" => "Six reasons your build passes locally and fails in CI",
        "source_url" => "https://dev.to/fernforge/six-reasons-your-build-passes-locally-and-fails-in-ci-and-how-to-catch-each-before-you-push-2dgg"
      }

      BRANCH = "configurable-shipping".freeze

      def build_world
        data = empty_world
        data["hosts"]["laptop"] = ShopWorld.laptop
        data["session"] = { "host" => "laptop", "user" => "dev", "cwd" => DeliveryWorld::ROOT }
        repo = DeliveryWorld.add_repo(data, history: [
          [ "Initial shop", DeliveryWorld.base_files ],
          [ "Add cart tests", DeliveryWorld.base_files ]
        ], env_file: "# Local settings, not committed (see .gitignore)\nFREE_SHIPPING_FROM=50\n")

        world = World.new(data)
        r = Repo.new(world)
        r.data["branches"][BRANCH] = r.head_sha
        r.data["branch"] = BRANCH
        world.write_file("#{DeliveryWorld::ROOT}/app/models/cart.rb", DeliveryWorld::CART_FROM_ENV, "laptop")
        r.stage_all
        r.commit!("Read free-shipping threshold from ENV", author: "you")
        repo["remote"][BRANCH] = r.head_sha
        pr = r.open_pr!("Make free-shipping threshold configurable", BRANCH)
        pr["number"] = 14
        world.clock = 0
        DeliveryCi.advance(world.tap { |w| w.clock = DeliveryCi::RUN_TICKS }, self)
        world.clock = 0
        world.data["messages"].clear
        data
      end

      def objectives
        [
          Objective.new(id: "checks", title: "See which check failed",
            hint: "Ask GitHub about your PR: `gh pr checks`.",
            check: ->(w) { inspected?(w, :gh, "pr checks") || inspected?(w, :gh, "pr view") }),
          Objective.new(id: "ci-log", title: "Read the failing test in the CI log",
            hint: "`gh run view --log-failed` shows the part of the log that failed.",
            check: ->(w) { inspected?(w, :gh, "run view") }),
          Objective.new(id: "local", title: "Run the tests on your laptop",
            hint: "From ~/shop run `bin/rails test`. Do they fail here too?",
            check: ->(w) { inspected?(w, :tests) }),
          Objective.new(id: "difference", title: "Find what's different between your laptop and CI",
            hint: "Look at what changed: `git log --oneline` and `git diff main`. Then `ls -a` and `cat .env`. CI doesn't have your .env file.",
            check: ->(w) { inspected?(w, :read, "#{DeliveryWorld::ROOT}/.env") || inspected?(w, :ls_hidden) }),
          Objective.new(id: "fix", title: "Make the code work without your .env",
            hint: "Give the code a default so it works anywhere: `sed -i 's/ENV\\[\"FREE_SHIPPING_FROM\"\\]/ENV.fetch(\"FREE_SHIPPING_FROM\", \"50\")/' app/models/cart.rb`, then `bin/rails test`.",
            check: ->(w) { clean_pass?(Repo.new(w).working_tree) || clean_pass?(Repo.new(w).snapshot) }),
          Objective.new(id: "green", title: "Commit, push and get CI green",
            hint: "`git commit -am \"Default the free-shipping threshold\"`, `git push`, then `gh pr checks` until it passes.",
            check: lambda { |w|
              repo = Repo.new(w)
              repo.prs.any? { |pr| repo.latest_run(pr)&.dig("conclusion") == "success" }
            })
        ]
      end

      # Would the tests pass on a clean CI machine?
      def clean_pass?(files) = DeliveryWorld.run_tests(files, DeliveryWorld.ci_env(files)).first

      def on_inspect(world, kind, target)
        super
        super(world, :ls_hidden, target) if kind == :ls && world.history.last&.dig("input").to_s.match?(/\s-\w*a/)
      end

      def run_tests(world, files)
        env = DeliveryWorld.parse_env_file(Repo.new(world).ignored_file(".env"))
        DeliveryWorld.run_tests(files, env)
      end

      def tick(world) = DeliveryCi.advance(world, self)
      def map(world) = DeliveryWorld.map(world)
      def logs(_world) = {}
    end
  end
end
