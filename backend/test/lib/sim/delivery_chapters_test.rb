require "test_helper"

class Sim::DeliveryChaptersTest < ActiveSupport::TestCase
  def play(engine, *inputs)
    inputs.flat_map { |i| engine.execute(i).completed.map { |c| c[:id] } }
  end

  def wait_for_ci(engine, ticks = 3) = ticks.times.flat_map { engine.tick.completed.map { |c| c[:id] } }

  test "github: the full flow completes every objective in order" do
    e = Sim::Engine.start("github-first-pr")
    ids = play(e, "cd ~/shop", "git status", "git switch -c free-shipping-banner",
      "echo '<p class=\"banner\">Free shipping on orders over $50</p>' > app/views/layouts/_banner.html.erb",
      "git add app/views/layouts/_banner.html.erb", "git commit -m \"Add free shipping banner\"",
      "git push -u origin free-shipping-banner", "gh pr create --title \"Add free shipping banner\"")
    ids += wait_for_ci(e)
    assert_equal %w[open-repo branch edit commit push open-pr], ids
    assert e.finished?
  end

  test "github: guard rails explain what to do" do
    e = Sim::Engine.start("github-first-pr")
    assert_match "not a git repository", e.execute("git status").output
    e.execute("cd ~/shop")
    assert_match "make a branch", e.execute("gh pr create --title x").output.downcase
    e.execute("git switch -c b")
    assert_match "nothing to commit", e.execute("git commit -m x").output
    assert_match "write a message", e.execute("git commit").output
    assert_match "push the current branch", e.execute("gh pr create --title x").output
  end

  test "github: git status shows changes and .env stays ignored" do
    e = Sim::Engine.start("github-first-pr")
    e.execute("cd ~/shop")
    e.execute("echo hi > notes.txt")
    out = e.execute("git status").output
    assert_match "Untracked files", out
    assert_match "notes.txt", out
  end

  test "ci: starts red, passes locally, and the full fix turns CI green" do
    e = Sim::Engine.start("ci-works-on-my-machine")
    assert_match "failed", e.execute("gh pr checks").output
    assert_match "Expected: 4.99", e.execute("gh run view --log-failed").output
    assert_match "0 failures", e.execute("bin/rails test").output
    e.execute("ls -a")
    e.execute(%q(sed -i 's/ENV\["FREE_SHIPPING_FROM"\]/ENV.fetch("FREE_SHIPPING_FROM", "50")/' app/models/cart.rb))
    assert_match "0 failures", e.execute("bin/rails test").output
    e.execute("git commit -am \"Default the free-shipping threshold\"")
    assert_match "CI started", e.execute("git push").output
    wait_for_ci(e)
    assert_match "passed", e.execute("gh pr checks").output
    assert e.finished?, e.objectives.inspect
  end

  test "ci: deleting .env reproduces the failure locally" do
    e = Sim::Engine.start("ci-works-on-my-machine")
    e.execute("rm .env")
    assert_match "1 failures", e.execute("bin/rails test").output
  end

  test "ci: setting the variable in the workflow also fixes CI" do
    e = Sim::Engine.start("ci-works-on-my-machine")
    e.execute("sed -i 's/RAILS_ENV: test/RAILS_ENV: test\\n      FREE_SHIPPING_FROM: 50/' .github/workflows/ci.yml")
    files = Sim::Repo.new(e.world).working_tree
    assert_equal "50", Sim::DeliveryWorld.ci_env(files)["FREE_SHIPPING_FROM"]
  end

  test "deploy: health is green while checkout fails, and the full fix works" do
    e = Sim::Engine.start("deploy-rollback")
    assert_match "200 OK", e.execute("curl -i https://shop.example/health").output
    assert_match "500", e.execute("curl -i -X POST https://shop.example/checkout").output
    assert_match "r43", e.execute("deploy releases").output
    assert_match "payments.internal/v2", e.execute("deploy logs").output
    e.execute("deploy rollback r42")
    assert_match "200 OK", e.execute("curl -i -X POST https://shop.example/checkout").output
    bad = Sim::Repo.new(e.world).log.first.first
    e.execute("git revert #{bad}")
    e.execute("git push")
    assert e.finished?, e.objectives.inspect
    assert_empty e.world.firing_alerts
  end

  test "deploy: the map shows production in trouble until the rollback" do
    e = Sim::Engine.start("deploy-rollback")
    prod = -> { e.scenario.map(e.world)["nodes"].find { |n| n["id"] == "production" } }
    assert_equal "bad", prod.call["status"]
    e.execute("deploy rollback r42")
    assert_equal "ok", prod.call["status"]
  end
end
