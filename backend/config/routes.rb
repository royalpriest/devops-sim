Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    resources :scenarios, only: :index
    resources :runs, only: %i[create show] do
      member do
        post :command, path: "commands"
        post :tick
      end
    end
  end

  mount ActionCable.server => "/cable"
end
