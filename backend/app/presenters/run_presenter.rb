# The JSON shape the frontend works with. `full` is the whole picture (for
# page load); `update` is what a single step changed, plus the live panels.
class RunPresenter
  def initialize(run)
    @run = run
    @engine = run.engine
    @world = @engine.world
  end

  def full
    scenario = @run.scenario
    {
      id: @run.id,
      status: @run.status,
      scenario: {
        key: scenario.key, title: scenario.title, topic: scenario.topic,
        chapter: scenario.chapter, summary: scenario.summary, briefing: scenario.briefing,
        focus_metric: scenario.focus_metric
      }
    }.merge(live)
  end

  def update(step)
    {
      type: "step",
      output: step.output,
      exit_code: step.exit_code,
      notices: step.notices,
      completed: step.completed
    }.merge(live)
  end

  private

  def live
    {
      id: @run.id,
      status: @run.status,
      clock: @world.clock,
      time: @world.timestamp,
      prompt: @engine.prompt,
      objectives: @engine.objectives,
      alerts: @world.alerts,
      metrics: @world.data["metrics"],
      services: services,
      current_host: @world.current_host,
      hint: @engine.scenario.hint_for(@world),
      map: @engine.scenario.map(@world),
      logs: @engine.scenario.logs(@world)
    }
  end

  def services
    @world.data["hosts"].select { |_, h| h["monitored"] }.to_h do |name, host|
      [ name, host["services"].transform_values { |s| s["state"] } ]
    end
  end
end
