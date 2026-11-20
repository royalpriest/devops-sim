require "test_helper"

class RunChannelTest < ActionCable::Channel::TestCase
  test "streams updates for a run" do
    run = Run.start!("linux-disk-full")
    subscribe run_id: run.id
    assert subscription.confirmed?
    assert_has_stream_for run

    assert_broadcasts(run, 1) { run.execute!("whoami") }
  end

  test "rejects unknown runs" do
    subscribe run_id: 0
    assert subscription.rejected?
  end
end
