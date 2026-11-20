module Sim
  # Drives one run: feeds input to the Shell, advances the clock, lets the
  # scenario react, and works out which objectives just got completed.
  class Engine
    Step = Struct.new(:output, :exit_code, :notices, :completed, keyword_init: true)

    attr_reader :world, :scenario

    def self.start(scenario_key)
      scenario = Scenario.find(scenario_key).new
      world = World.new(scenario.build_world)
      world.record_metrics
      new(world, scenario)
    end

    def initialize(world, scenario)
      @world = world.is_a?(World) ? world : World.new(world)
      @scenario = scenario
    end

    def execute(input)
      world.history << { "tick" => world.clock, "host" => world.current_host, "input" => input.to_s.strip }
      world.history.shift while world.history.size > 500
      result = Shell.new(world, scenario).run(input)
      notices, completed = advance(1)
      Step.new(output: result.output, exit_code: result.exit_code, notices: notices, completed: completed)
    end

    # Let time pass without a command (the UI calls this every few seconds).
    def tick(ticks = 1)
      notices, completed = advance(ticks)
      Step.new(output: "", exit_code: 0, notices: notices, completed: completed)
    end

    def prompt
      s = world.session
      dir = s["cwd"] == world.home ? "~" : s["cwd"].sub(/\A#{Regexp.escape(world.home)}\//, "~/")
      "#{s['user']}@#{s['host']}:#{dir}#{s['user'] == 'root' ? '#' : '$'}"
    end

    def objectives
      scenario.objectives.map do |o|
        { id: o.id, title: o.title, done: world.data["completed"].include?(o.id) }
      end
    end

    def finished? = scenario.objectives.all? { |o| world.data["completed"].include?(o.id) }

    private

    # Messages the scenario wants shown (alerts, story beats) go through
    # world["messages"]; we drain them here so each is delivered once.
    def advance(ticks)
      ticks.clamp(1, 30).times do
        world.clock += 1
        scenario.tick(world)
        world.record_metrics
      end
      notices = world.data["messages"].dup
      world.data["messages"].clear
      [ notices, check_objectives ]
    end

    # Objectives are a story, so they complete in order: one can only tick
    # off once the ones before it are done (several may finish in one step).
    def check_objectives
      done = world.data["completed"]
      newly = []
      scenario.objectives.each do |o|
        next if done.include?(o.id)
        break unless o.check.call(world)
        done << o.id
        newly << { id: o.id, title: o.title }
      end
      newly
    end
  end
end
