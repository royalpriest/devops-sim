require "test_helper"

class Sim::MonitoringMemoryLeakTest < ActiveSupport::TestCase
  setup do
    @engine = Sim::Engine.start("monitoring-memory-leak")
    @world = @engine.world
  end

  def wait_for_alert
    30.times do
      return if @world.firing_alerts.any?
      @engine.tick
    end
    flunk "alert never fired"
  end

  test "starts calm, then memory climbs until an alert fires" do
    assert_empty @world.alerts
    start = @world.memory_percent("web-01")
    wait_for_alert
    assert_operator @world.memory_percent("web-01"), :>=, 85
    assert_operator start, :<, 60
    assert_equal "HighMemoryUsage", @world.firing_alerts.first["id"]
  end

  test "metrics record one point per tick for the dashboard" do
    3.times { @engine.tick }
    assert_equal 4, @world.data["metrics"]["web-01"].size
    assert_equal %w[cpu disk memory t], @world.data["metrics"]["web-01"].last.keys.sort
  end

  test "restarting without fixing the config only buys time" do
    wait_for_alert
    @engine.execute("ssh web-01")
    @engine.execute("sudo systemctl restart shop-worker")
    before = @world.memory_percent("web-01")
    3.times { @engine.tick }
    assert_operator @world.memory_percent("web-01"), :>, before
  end

  test "left alone, the kernel kills the worker and systemd restarts it" do
    wait_for_alert
    notices = 20.times.flat_map { @engine.tick.notices }
    assert notices.any? { |n| n["text"].include?("ran out of memory") }
    assert_equal "active", @world.service("shop-worker", "web-01")["state"]
    assert_match "Out of memory", @world.file("/var/log/syslog", "web-01")["content"]
  end

  test "the full fix completes every objective in order" do
    wait_for_alert
    ids = [
      "alerts", "ssh web-01", "ps aux --sort=-%mem", "journalctl -u shop-worker",
      "sudo sed -i 's/REPORT_CACHE_MAX=0.*/REPORT_CACHE_MAX=500/' /etc/shop/worker.env",
      "sudo systemctl restart shop-worker"
    ].flat_map { |i| @engine.execute(i).completed.map { |c| c[:id] } }

    assert_equal %w[see-alert connect find-process trace-cause fix-config recover], ids
    assert @engine.finished?
    5.times { @engine.tick }
    assert_operator @world.memory_percent("web-01"), :<, 70
  end
end
