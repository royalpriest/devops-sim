module Sim
  # The setting for the delivery chapters (GitHub, CI, Deploy): the shop's
  # code on your laptop in ~/shop, its GitHub repo, CI, and production.
  module DeliveryWorld
    ROOT = "/home/dev/shop".freeze

    module_function

    CART_FIXED = <<~RUBY.freeze
      class Cart
        FREE_SHIPPING_FROM = 50

        def initialize(subtotal)
          @subtotal = subtotal
        end

        def shipping
          free_shipping? ? 0 : 4.99
        end

        def free_shipping?
          @subtotal >= FREE_SHIPPING_FROM
        end
      end
    RUBY

    CART_FROM_ENV = <<~RUBY.freeze
      class Cart
        def initialize(subtotal)
          @subtotal = subtotal
        end

        def shipping
          free_shipping? ? 0 : 4.99
        end

        # The threshold now comes from the environment so marketing can change it.
        def free_shipping?
          @subtotal >= ENV["FREE_SHIPPING_FROM"].to_i
        end
      end
    RUBY

    CART_TEST = <<~RUBY.freeze
      require "test_helper"

      class CartTest < ActiveSupport::TestCase
        test "small carts pay shipping" do
          assert_equal 4.99, Cart.new(20).shipping
        end

        test "carts of $50 or more ship free" do
          assert_equal 0, Cart.new(50).shipping
        end
      end
    RUBY

    CI_WORKFLOW = <<~YAML.freeze
      name: CI
      on: [pull_request]

      jobs:
        test:
          runs-on: ubuntu-latest
          env:
            RAILS_ENV: test
          steps:
            - uses: actions/checkout@v7
            - uses: ruby/setup-ruby@v1
            - run: bin/rails test
    YAML

    BANNER_FILE = { "app/views/layouts/_banner.html.erb" => "<p class=\"banner\">Free shipping on orders over $50</p>\n" }.freeze

    PAYMENTS_V1 = "endpoint: https://payments.internal/v1/charge\ntimeout_seconds: 5\n".freeze
    PAYMENTS_V2 = "endpoint: https://payments.internal/v2/charge\ntimeout_seconds: 5\n".freeze

    def base_files(cart: CART_FIXED, payments: PAYMENTS_V1)
      {
        "README.md" => "# Shop\n\nThe Rails app behind shop.example.\n\nRun the tests with `bin/rails test`.\n",
        ".gitignore" => ".env\nlog/\ntmp/\n",
        ".github/workflows/ci.yml" => CI_WORKFLOW,
        "app/models/cart.rb" => cart,
        "app/views/layouts/_banner.html.erb" => "<%# TODO: free shipping banner goes here %>\n",
        "config/payments.yml" => payments,
        "test/models/cart_test.rb" => CART_TEST
      }
    end

    # Builds ~/shop on the laptop with the given history.
    # history: [[message, files], ...] oldest first, all on main.
    def add_repo(data, history:, env_file: nil)
      laptop = data["hosts"]["laptop"]
      repo = { "root" => ROOT, "branch" => "main", "staged" => {}, "commits" => {}, "branches" => {}, "remote" => {}, "prs" => [] }
      parent = nil
      history.each_with_index do |(message, files, author), i|
        sha = Digest::SHA1.hexdigest("#{message}#{i}")[0, 7]
        repo["commits"][sha] = { "message" => message, "parent" => parent, "files" => files, "author" => author || "sam", "tick" => -100 + i }
        parent = sha
      end
      repo["branches"]["main"] = parent
      repo["remote"]["main"] = parent
      history.last[1].each { |path, content| laptop["fs"]["#{ROOT}/#{path}"] = ShopWorld.text(content) }
      laptop["fs"]["#{ROOT}/.env"] = ShopWorld.text(env_file) if env_file
      laptop["dirs"] << ROOT
      data["repo"] = repo
      repo
    end

    # Which free-shipping threshold the code ends up using, given env vars.
    # Understands the forms a beginner is likely to write.
    def threshold(cart_rb, env)
      if (m = cart_rb.match(/ENV\.fetch\(\s*["']FREE_SHIPPING_FROM["']\s*,\s*["']?(\d+)["']?\s*\)/))
        (env["FREE_SHIPPING_FROM"] || m[1]).to_i
      elsif (m = cart_rb.match(/ENV\[\s*["']FREE_SHIPPING_FROM["']\s*\]\s*(?:\|\|\s*["']?(\d+)["']?)?/))
        value = env["FREE_SHIPPING_FROM"] || m[1]
        value.to_i
      elsif (m = cart_rb.match(/FREE_SHIPPING_FROM\s*=\s*(\d+)/))
        m[1].to_i
      else
        0
      end
    end

    def parse_env_file(content)
      content.to_s.lines.filter_map { |l| l.strip.split("=", 2) if l.include?("=") && !l.start_with?("#") }.to_h
    end

    def ci_env(files)
      files[".github/workflows/ci.yml"].to_s.scan(/^\s+([A-Z_]+):\s*["']?([^"'\n]+)["']?\s*$/).to_h
    end

    # The two cart tests, run against a set of files and environment.
    def run_tests(files, env)
      return [ false, [ "Error: app/models/cart.rb is missing" ] ] unless files["app/models/cart.rb"]
      t = threshold(files["app/models/cart.rb"], env)
      results = [
        [ "small carts pay shipping", 9, t > 20, "Expected: 4.99\n  Actual: 0" ],
        [ "carts of $50 or more ship free", 13, t <= 50, "Expected: 0\n  Actual: 4.99" ]
      ]
      failures = results.reject { |r| r[2] }
      lines = [ "Running 2 tests in a single process", "# Running:", "",
                results.map { |r| r[2] ? "." : "F" }.join, "" ]
      failures.each do |name, line, _, detail|
        lines += [ "Failure:", "CartTest#test_#{name.tr(' $', '_').squeeze('_')} [test/models/cart_test.rb:#{line}]:", detail, "" ]
      end
      lines << "2 runs, 2 assertions, #{failures.size} failures, 0 errors, 0 skips"
      [ failures.empty?, lines ]
    end

    # --- map --------------------------------------------------------------

    def map(world, production: false)
      repo = Repo.new(world)
      pr = repo.prs.reverse.find { |p| p["state"] == "open" }
      run = pr && repo.latest_run(pr)
      changes = repo.changes
      dirty = (changes[:staged] + changes[:unstaged] + changes[:untracked]).any?
      ci_status, ci_detail =
        if run.nil? then [ "ok", "waiting for a PR" ]
        elsif run["status"] == "in_progress" then [ "warn", "running…" ]
        elsif run["conclusion"] == "success" then [ "ok", "passing" ]
        else [ "bad", "failing" ]
        end
      row = production ? 30 : 45
      nodes = [
        { "id" => "laptop", "label" => "Your laptop", "kind" => "~/shop", "host" => "dev", "status" => "ok",
          "detail" => "on #{repo.branch}#{dirty ? ' · changes' : ''}", "inspect" => "git status", "pos" => [ 12, row ], "pos_narrow" => [ 26, 9 ] },
        { "id" => "github", "label" => "GitHub", "kind" => "shop/shop", "host" => "github.com", "status" => "ok",
          "detail" => pr ? "PR ##{pr['number']} open" : "#{world.data['repo']['remote'].size} branch#{'es' unless world.data['repo']['remote'].size == 1}",
          "inspect" => pr ? "gh pr view" : "git log --oneline", "pos" => [ 38, row ], "pos_narrow" => [ 74, 9 ] },
        { "id" => "ci", "label" => "CI", "kind" => "bin/rails test", "host" => "github actions", "status" => ci_status,
          "detail" => ci_detail, "inspect" => "gh pr checks", "pos" => [ 64, row ], "pos_narrow" => [ 26, 37 ] }
      ]
      edges = [ %w[laptop github], %w[github ci] ]
      if production
        d = world.data["deploy"]
        rate = world.host("web-01")["error_rate"].to_i
        nodes << { "id" => "production", "label" => "Production", "kind" => "shop.example", "host" => "web-01",
                   "status" => rate >= 5 ? "bad" : "ok", "detail" => "#{d['current']} · #{rate}% errors", "inspect" => "deploy status",
                   "pos" => [ 64, 72 ], "pos_narrow" => [ 74, 37 ] }
        nodes << { "id" => "payments", "label" => "Payments API", "kind" => "payments.internal", "host" => "internal", "status" => "ok",
                   "detail" => "v1 only", "inspect" => "deploy logs", "pos" => [ 88, 72 ], "pos_narrow" => [ 74, 64 ] }
        nodes << { "id" => "users", "label" => "Shoppers", "kind" => "checkout", "host" => "internet", "status" => rate >= 5 ? "bad" : "ok",
                   "detail" => rate >= 5 ? "seeing errors" : "happy", "inspect" => "curl https://shop.example/checkout",
                   "pos" => [ 41, 72 ], "pos_narrow" => [ 26, 64 ] }
        edges += [ %w[ci production], %w[users production], %w[production payments] ]
      end
      { "nodes" => nodes, "edges" => edges }
    end
  end
end
