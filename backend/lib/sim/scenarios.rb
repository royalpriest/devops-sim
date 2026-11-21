module Sim
  # Every playable chapter. Each one stands on its own, so the order of the
  # story can change without touching the engine.
  module Scenarios
    ALL = [
      GithubFirstPr,
      CiWorksOnMyMachine,
      DeployRollback,
      LinuxDiskFull,
      MonitoringMemoryLeak
    ].freeze
  end
end
