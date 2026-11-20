module Api
  class RunsController < ApplicationController
    before_action :set_run, except: :create

    def create
      run = Run.start!(params.require(:scenario))
      render json: RunPresenter.new(run).full, status: :created
    rescue KeyError
      render json: { error: "Unknown scenario" }, status: :unprocessable_content
    end

    def show
      render json: RunPresenter.new(@run).full
    end

    # POST /api/runs/:id/commands { input: "df -h" }
    def command
      input = params.require(:input).to_s
      return render(json: { error: "Command too long" }, status: :unprocessable_content) if input.length > 500
      step = @run.execute!(input)
      render json: RunPresenter.new(@run).update(step)
    end

    # POST /api/runs/:id/tick { ticks: 1 }: time passes while the player reads.
    def tick
      step = @run.tick!(params.fetch(:ticks, 1).to_i)
      render json: RunPresenter.new(@run).update(step)
    end

    private

    def set_run
      @run = Run.find(params[:id])
    end
  end
end
