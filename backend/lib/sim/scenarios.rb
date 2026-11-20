module Sim
  # Every playable chapter. Each one stands on its own, so the order of the
  # story can change without touching the engine.
  module Scenarios
    ALL = [
      LinuxDiskFull,
      MonitoringMemoryLeak
    ].freeze
  end
end
