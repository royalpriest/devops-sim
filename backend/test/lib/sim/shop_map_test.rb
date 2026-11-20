require "test_helper"

class Sim::ShopMapTest < ActiveSupport::TestCase
  def node(engine, id) = engine.scenario.map(engine.world)["nodes"].find { |n| n["id"] == id }

  test "the linux chapter shows a crashed app and a full disk" do
    engine = Sim::Engine.start("linux-disk-full")
    assert_equal "bad", node(engine, "shop-web")["status"]
    assert_equal "bad", node(engine, "disk")["status"]
    assert_equal "ok", node(engine, "nginx")["status"]
    assert_equal "systemctl status shop-web", node(engine, "shop-web")["inspect"]
  end

  test "the monitoring chapter makes the worker glow as it leaks" do
    engine = Sim::Engine.start("monitoring-memory-leak")
    assert_equal "ok", node(engine, "shop-worker")["status"]
    10.times { engine.tick }
    assert_equal "warn", node(engine, "shop-worker")["status"]
    assert_match "high memory", node(engine, "shop-worker")["detail"]
  end

  test "the laptop node follows the ssh session" do
    engine = Sim::Engine.start("linux-disk-full")
    assert_equal "you are here", node(engine, "laptop")["detail"]
    engine.execute("ssh web-01")
    assert_equal "connected over ssh", node(engine, "laptop")["detail"]
  end

  test "every edge points at a real node" do
    map = Sim::Engine.start("linux-disk-full").then { |e| e.scenario.map(e.world) }
    ids = map["nodes"].map { |n| n["id"] }
    assert map["edges"].flatten.all? { |id| ids.include?(id) }
  end
end
