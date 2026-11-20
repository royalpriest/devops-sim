require "test_helper"

class Sim::ShellTest < ActiveSupport::TestCase
  setup do
    @engine = Sim::Engine.start("linux-disk-full")
  end

  def run_cmd(input) = @engine.execute(input)

  test "unknown commands look like bash" do
    step = run_cmd("frobnicate")
    assert_equal "bash: frobnicate: command not found", step.output
    assert_equal 127, step.exit_code
  end

  test "service commands on the laptop point the player to the server" do
    assert_match "ssh web-01", run_cmd("systemctl status shop-web").output
  end

  test "ssh changes the prompt and exit comes back" do
    run_cmd("ssh web-01")
    assert_equal "deploy@web-01:~$", @engine.prompt
    run_cmd("exit")
    assert_equal "dev@laptop:~$", @engine.prompt
  end

  test "ssh to an unknown host fails" do
    assert_match "Could not resolve hostname", run_cmd("ssh db-99").output
  end

  test "system files need sudo" do
    run_cmd("ssh web-01")
    assert_match "Permission denied", run_cmd("rm /var/log/shop/debug.log").output
    assert @engine.world.file?("/var/log/shop/debug.log")
    run_cmd("sudo rm /var/log/shop/debug.log")
    assert_not @engine.world.file?("/var/log/shop/debug.log")
  end

  test "globs, pipes and sort -h work together" do
    run_cmd("ssh web-01")
    output = run_cmd("du -sh /var/log/* | sort -rh | head -1").output
    assert_match %r{\A1\dG\t/var/log/shop\z}, output
  end

  test "grep and wc filters" do
    run_cmd("ssh web-01")
    assert_equal "LOG_LEVEL=debug", run_cmd("cat /etc/shop/web.env | grep LOG").output
    assert_equal "3", run_cmd("cat /etc/shop/web.env | wc -l").output
  end

  test "sed -i edits a file in place with a regex" do
    run_cmd("ssh web-01")
    run_cmd("sudo sed -i 's/LOG_LEVEL=.*/LOG_LEVEL=warn/' /etc/shop/web.env")
    assert_equal "warn", @engine.world.env_value("/etc/shop/web.env", "LOG_LEVEL")
  end

  test "redirection writes into the home directory" do
    run_cmd("echo hello > notes.txt")
    run_cmd("echo again >> notes.txt")
    assert_equal "hello\nagain", run_cmd("cat notes.txt").output
  end

  test "&& stops at the first failure" do
    output = run_cmd("cat nope.txt && echo should-not-print").output
    assert_no_match "should-not-print", output
  end

  test "cd and ls navigate the fake filesystem" do
    run_cmd("ssh web-01")
    run_cmd("cd /var/log")
    assert_equal "deploy@web-01:/var/log$", @engine.prompt
    assert_equal "nginx/  shop/  syslog", run_cmd("ls").output
  end

  test "unmatched quotes are a syntax error, not a crash" do
    assert_match "syntax error", run_cmd("echo 'oops").output
  end
end
