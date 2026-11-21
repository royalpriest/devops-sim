module Sim
  module Scenarios
    # Chapter: the everyday GitHub flow. Branch, change, commit, push, PR.
    class GithubFirstPr < Scenario
      self.key = "github-first-pr"
      self.chapter = 1
      self.topic = "GitHub"
      self.title = "Open your first pull request"
      self.summary = "Make a small change on a branch, push it, and open a pull request."
      self.focus_metric = nil
      self.briefing = <<~TEXT
        Welcome to the team! Your first task from the product channel:
          "Can we show 'Free shipping on orders over $50' at the top of the shop?"
        The code is in ~/shop. Changes go through a pull request, never straight to main.
      TEXT
      self.real_world = {
        "text" => "Almost every team works like this: no one pushes straight to main. A pull request lets teammates and CI check a change before it ships, and it leaves a record of why the change was made.",
        "source_title" => "GitHub Docs: About pull requests",
        "source_url" => "https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/about-pull-requests"
      }

      BANNER = "app/views/layouts/_banner.html.erb".freeze

      def build_world
        data = empty_world
        data["hosts"]["laptop"] = ShopWorld.laptop
        data["session"] = { "host" => "laptop", "user" => "dev", "cwd" => "/home/dev" }
        DeliveryWorld.add_repo(data, history: [
          [ "Initial shop", DeliveryWorld.base_files ],
          [ "Add cart tests", DeliveryWorld.base_files ]
        ])
        data
      end

      def objectives
        [
          Objective.new(id: "open-repo", title: "Go to the shop's code",
            hint: "The code lives in ~/shop. Run `cd ~/shop`, then `git status` to look around.",
            check: ->(w) { Repo.new(w).inside?(w.session["cwd"]) }),
          Objective.new(id: "branch", title: "Create a branch for your change",
            hint: "Never work on main. Make a branch: `git switch -c free-shipping-banner`.",
            check: ->(w) { w.data["repo"]["branches"].keys.any? { |b| b != "main" } }),
          Objective.new(id: "edit", title: "Add the banner text",
            hint: "Replace the TODO in #{BANNER}: echo '<p class=\"banner\">Free shipping on orders over $50</p>' > #{BANNER}",
            check: ->(w) { banner_done?(Repo.new(w).working_tree[BANNER]) || banner_committed?(w) }),
          Objective.new(id: "commit", title: "Commit your change",
            hint: "Stage it with `git add #{BANNER}`, then `git commit -m \"Add free shipping banner\"`.",
            check: ->(w) { banner_committed?(w) }),
          Objective.new(id: "push", title: "Push your branch to GitHub",
            hint: "Send it up: `git push -u origin <your-branch>`. `git branch` shows the name.",
            check: ->(w) { w.data["repo"]["remote"].any? { |b, sha| b != "main" && banner_done?(Repo.new(w).snapshot(sha)[BANNER]) } }),
          Objective.new(id: "open-pr", title: "Open a pull request and let CI pass",
            hint: "Run `gh pr create --title \"Add free shipping banner\"`, then `gh pr checks` until it's green.",
            check: lambda { |w|
              repo = Repo.new(w)
              repo.prs.any? { |pr| repo.latest_run(pr)&.dig("conclusion") == "success" }
            })
        ]
      end

      def banner_done?(content) = content.to_s.match?(/free shipping/i)

      def banner_committed?(world)
        repo = Repo.new(world)
        world.data["repo"]["branches"].any? { |b, sha| b != "main" && banner_done?(repo.snapshot(sha)[BANNER]) }
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
