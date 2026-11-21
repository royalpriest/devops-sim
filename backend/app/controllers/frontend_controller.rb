# Serves the built React app (see the Dockerfile). Its assets are fingerprinted and
# cached for a year by the static file server, so the page itself must not be cached.
class FrontendController < ActionController::API
  def show
    page = Rails.public_path.join("app.html")
    return head :not_found unless page.exist?

    response.headers["Cache-Control"] = "no-cache"
    send_file page, type: "text/html", disposition: "inline"
  end
end
