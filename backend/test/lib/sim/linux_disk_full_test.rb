require "test_helper"

class Sim::LinuxDiskFullTest < ActiveSupport::TestCase
  setup do
    @engine = Sim::Engine.start("linux-disk-full")
    @world = @engine.world
  end

  def completed_ids(*inputs) = inputs.flat_map { |i| @engine.execute(i).completed.map { |c| c[:id] } }

  test "starts with a full disk, a crashed app and a firing alert" do
    assert_equal 100, @world.disk_percent("web-01")
    assert_equal "failed", @world.service("shop-web", "web-01")["state"]
    assert_equal [ "SiteDown" ], @world.firing_alerts.map { |a| a["id"] }
  end

  test "the app cannot start while the disk is full" do
    @engine.execute("ssh web-01")
    step = @engine.execute("sudo systemctl start shop-web")
    assert_match "failed", step.output
    assert_match "No space left on device", @engine.execute("journalctl -u shop-web").output
  end

  test "the full fix completes every objective in order" do
    ids = completed_ids(
      "ssh web-01", "systemctl status shop-web", "du -sh /var/log/*", "ls -lh /var/log/shop",
      "sudo truncate -s 0 /var/log/shop/debug.log",
      "sudo sed -i 's/LOG_LEVEL=debug/LOG_LEVEL=info/' /etc/shop/web.env",
      "sudo systemctl restart shop-web", "curl https://shop.example/health"
    )
    assert_equal %w[connect diagnose find-culprit free-space stop-debug recover], ids
    assert @engine.finished?
    assert_empty @world.firing_alerts
  end

  test "restarting with debug logging still on fills the disk again" do
    @engine.execute("ssh web-01")
    @engine.execute("sudo truncate -s 0 /var/log/shop/debug.log")
    @engine.execute("sudo systemctl start shop-web")
    assert_equal "active", @world.service("shop-web", "web-01")["state"]

    notices = 15.times.flat_map { @engine.tick.notices }
    assert_equal "failed", @world.service("shop-web", "web-01")["state"]
    assert notices.any? { |n| n["text"].include?("crashed again") }
  end

  test "the site check only counts after the app is back" do
    @engine.execute("ssh web-01")
    assert_match "502 Bad Gateway", @engine.execute("curl https://shop.example/").output
  end
end
