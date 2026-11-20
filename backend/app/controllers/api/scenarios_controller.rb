module Api
  class ScenariosController < ApplicationController
    def index
      render json: Sim::Scenario.all.map { |s|
        { key: s.key, title: s.title, topic: s.topic, chapter: s.chapter, summary: s.summary }
      }
    end
  end
end
