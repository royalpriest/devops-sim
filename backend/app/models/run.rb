# One player's attempt at a scenario. The whole simulated environment lives
# in the `world` JSON column; Sim::Engine does the work, this model just
# loads and saves it and tells listeners what changed.
class Run < ApplicationRecord
  STATUSES = %w[active completed].freeze

  validates :status, inclusion: { in: STATUSES }
  validate :scenario_exists

  def self.start!(scenario_key)
    engine = Sim::Engine.start(scenario_key)
    create!(scenario_key: scenario_key, world: engine.world.to_h)
  end

  def scenario = Sim::Scenario.find(scenario_key)

  def engine
    @engine ||= Sim::Engine.new(Sim::World.new(world), scenario.new)
  end

  def execute!(input) = step! { engine.execute(input) }
  def tick!(ticks = 1) = step! { engine.tick(ticks) }

  private

  def step!
    with_lock do
      @engine = nil # pick up the row as locked, not a stale copy
      step = yield
      self.world = engine.world.to_h
      self.status = "completed" if engine.finished?
      save!
      RunChannel.broadcast_to(self, RunPresenter.new(self).update(step))
      step
    end
  end

  def scenario_exists
    Sim::Scenario.find(scenario_key)
  rescue KeyError
    errors.add(:scenario_key, "is not a known scenario")
  end
end
