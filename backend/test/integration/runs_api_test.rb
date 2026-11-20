require "test_helper"

class RunsApiTest < ActionDispatch::IntegrationTest
  test "lists scenarios" do
    get "/api/scenarios"
    assert_response :success
    assert_equal %w[linux-disk-full monitoring-memory-leak], response.parsed_body.map { |s| s["key"] }
  end

  test "starts a run, runs a command and saves the world" do
    post "/api/runs", params: { scenario: "linux-disk-full" }, as: :json
    assert_response :created
    run = response.parsed_body
    assert_equal "dev@laptop:~$", run["prompt"]
    assert_equal 6, run["objectives"].size

    post "/api/runs/#{run['id']}/commands", params: { input: "ssh web-01" }, as: :json
    assert_response :success
    body = response.parsed_body
    assert_equal "deploy@web-01:~$", body["prompt"]
    assert_equal [ "connect" ], body["completed"].map { |c| c["id"] }

    get "/api/runs/#{run['id']}"
    assert_equal "deploy@web-01:~$", response.parsed_body["prompt"]
  end

  test "tick advances time" do
    post "/api/runs", params: { scenario: "monitoring-memory-leak" }, as: :json
    id = response.parsed_body["id"]
    post "/api/runs/#{id}/tick", params: { ticks: 3 }, as: :json
    assert_equal 3, response.parsed_body["clock"]
  end

  test "rejects unknown scenarios" do
    post "/api/runs", params: { scenario: "nope" }, as: :json
    assert_response :unprocessable_content
  end

  test "rejects very long commands" do
    post "/api/runs", params: { scenario: "linux-disk-full" }, as: :json
    post "/api/runs/#{response.parsed_body['id']}/commands", params: { input: "a" * 501 }, as: :json
    assert_response :unprocessable_content
  end
end
