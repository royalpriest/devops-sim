module Sim
  # Fake GitHub Actions: a run takes two ticks, then runs the tests on the
  # pushed commit in a clean environment (only the workflow's env vars).
  module DeliveryCi
    RUN_TICKS = 2

    module_function

    def advance(world, scenario)
      repo = Repo.new(world)
      repo.prs.each do |pr|
        pr["runs"].each do |run|
          next unless run["status"] == "in_progress" && world.clock - run["started"] >= RUN_TICKS
          files = repo.snapshot(run["sha"])
          passed, lines = DeliveryWorld.run_tests(files, DeliveryWorld.ci_env(files))
          run["status"] = "completed"
          run["conclusion"] = passed ? "success" : "failure"
          run["tests"] = 2
          run["log"] = [ "Run actions/checkout@v7", "Run ruby/setup-ruby@v1", "Ruby 3.3 installed",
                         "Run bin/rails test", *lines.map { |l| "  #{l}" } ]
          run["log"] << "Error: Process completed with exit code 1." unless passed
          world.data["messages"] << (passed ?
            { "kind" => "resolved", "text" => "[CI] PR ##{pr['number']}: all checks passed." } :
            { "kind" => "alert", "text" => "[CI] PR ##{pr['number']}: test failed. Run `gh pr checks` for details." })
        end
      end
    end
  end
end
