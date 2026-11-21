require "test_helper"

class FrontendTest < ActionDispatch::IntegrationTest
  PAGE = Rails.public_path.join("app.html")

  teardown { PAGE.delete if PAGE.exist? }

  test "serves the built frontend at the root without caching it" do
    PAGE.write("<!doctype html><title>DevOps Simulator</title>")
    get "/"
    assert_response :success
    assert_equal "no-cache", response.headers["Cache-Control"]
    assert_includes response.body, "DevOps Simulator"
  end

  test "answers 404 when the frontend has not been built" do
    get "/"
    assert_response :not_found
  end
end
