module Sim
  # Base class for a chapter of the story. A scenario provides:
  #   - the starting World
  #   - objectives, each checked against the World after every step
  #   - time-based behaviour (#tick) that makes incidents happen and evolve
  #   - hooks the Shell calls so the scenario can react to what the player does
  class Scenario
    Objective = Struct.new(:id, :title, :hint, :check, keyword_init: true)

    class << self
      def all = Scenarios::ALL.sort_by(&:chapter)
      def find(key) = all.find { |s| s.key == key } || raise(KeyError, "Unknown scenario #{key}")

      attr_accessor :key, :title, :chapter, :topic, :summary, :briefing
    end

    def key = self.class.key

    def objectives = []

    def build_world
      raise NotImplementedError
    end

    # Called once per tick, after the player's command (or when time passes on its own).
    def tick(world); end

    # Hooks the Shell calls. Defaults do the generic, realistic thing.
    def on_inspect(world, kind, target)
      world.history.last&.then { |h| (h["inspected"] ||= []) << [ kind.to_s, target ] }
    end

    def on_file_changed(world, path); end
    def on_ssh(world, host); end

    def on_kill(world, process, _signal)
      world.processes.delete(process)
      if process["service"] && world.service_processes(process["service"]).empty?
        svc = world.service(process["service"])
        svc["state"] = "failed"
        svc["failed_at"] = world.clock
        world.journal(process["service"], "#{process['service']}.service: Main process exited, code=killed, status=9/KILL")
      end
    end

    # Returns an error message string, or nil on success.
    def on_service(world, name, action)
      svc = world.service(name)
      case action
      when "stop"
        stop_service(world, name)
      when "start", "restart"
        stop_service(world, name) if action == "restart"
        error = start_blocker(world, name)
        if error
          svc["state"] = "failed"
          svc["failed_at"] = world.clock
          world.journal(name, error)
          world.journal(name, "#{name}.service: Failed with result 'exit-code'.")
          return "Job for #{name}.service failed because the control process exited with error code.\n" \
                 "See \"systemctl status #{name}\" and \"journalctl -u #{name}\" for details."
        end
        start_service(world, name)
      end
      nil
    end

    # Return a log line explaining why the service can't start, or nil.
    def start_blocker(_world, _name) = nil

    def stop_service(world, name, host: world.current_host)
      world.processes(host).reject! { |p| p["service"] == name }
      svc = world.service(name, host)
      svc["state"] = "inactive"
      world.journal(name, "Stopped #{svc['description']}.", host)
    end

    def start_service(world, name, host: world.current_host)
      svc = world.service(name, host)
      svc["state"] = "active"
      svc["started_at"] = world.clock
      Array(svc["spawn"]).each do |spec|
        world.processes(host) << spec.merge("pid" => world.next_pid(host), "service" => name)
      end
      svc["pid"] = world.service_processes(name, host).first&.dig("pid")
      world.journal(name, "Started #{svc['description']}.", host)
      after_start(world, name, host)
    end

    def after_start(_world, _name, _host); end

    # [status, body] for curl, or nil if the host doesn't resolve.
    def http(_world, _url) = nil

    def hint_for(world)
      objectives.find { |o| !completed?(world, o) }&.hint
    end

    def completed?(world, objective)
      world.data["completed"].include?(objective.id)
    end

    # --- helpers for subclasses --------------------------------------------

    def ran?(world, pattern, host: nil, since: 0)
      world.history.any? do |h|
        h["tick"] >= since && (host.nil? || h["host"] == host) && h["input"].match?(pattern)
      end
    end

    def inspected?(world, kind, target = nil, since: 0)
      world.history.any? do |h|
        h["tick"] >= since && Array(h["inspected"]).any? do |k, t|
          k == kind.to_s && (target.nil? || t.to_s.start_with?(target))
        end
      end
    end

    def empty_world(clock: 0)
      { "clock" => clock, "hosts" => {}, "session" => {}, "alerts" => [], "metrics" => {},
        "history" => [], "flags" => {}, "fired" => [], "completed" => [], "messages" => [] }
    end
  end
end
