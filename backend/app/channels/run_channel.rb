# Live updates for one run: terminal output, alerts and metrics are pushed
# here after every command and every tick.
class RunChannel < ApplicationCable::Channel
  def subscribed
    run = Run.find_by(id: params[:run_id])
    run ? stream_for(run) : reject
  end
end
