# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require "mail"

module PgKeeper
  class TestNotify < Minitest::Test
    include TestHelpers

    def setup
      WebMock.disable_net_connect!
      Mail.defaults { delivery_method :test }
      Mail::TestMailer.deliveries.clear
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
    end

    def artifact
      { kind: "database", size_bytes: 4096, compression: "gzip", encryption: "aes256gcm",
        destinations: [Orchestrator::Destination.new(name: "local:/b", status: :ok)] }
    end

    def result(db, status, error: nil)
      r = Orchestrator::Result.new(database: db, status: status,
                                   artifacts: status == :failure ? [] : [artifact], duration_seconds: 2.0)
      r.error = error
      r
    end

    def summary(*results)
      report = Orchestrator::RunReport.new(results: results)
      Notify::Summary.new(report: report, run_id: "run-1", started_at: Time.utc(2026, 5, 1),
                          finished_at: Time.utc(2026, 5, 1, 0, 1), hostname: "db-host")
    end

    def success_summary = summary(result("app", :success))
    def failure_summary = summary(result("app", :failure, error: PgKeeper::DumpError.new("pg_dump exited 1")))

    # --- Summary rendering ------------------------------------------------

    def test_summary_event_success_vs_failure
      assert_equal :success, success_summary.event
      assert_equal :failure, failure_summary.event
    end

    def test_text_and_html_include_key_facts
      text = success_summary.to_text

      assert_includes text, "SUCCESS"
      assert_includes text, "app"
      assert_includes text, "gzip+aes256gcm"

      html = success_summary.to_html

      assert_includes html, "<table"
      assert_includes html, "app"
    end

    def test_html_escapes_error_text
      html = summary(result("app", :failure, error: PgKeeper::Error.new("bad <tag> & stuff"))).to_html

      assert_includes html, "&lt;tag&gt;"
      refute_includes html, "<tag>"
    end

    def test_payload_shape
      payload = success_summary.to_payload

      assert_equal "success", payload["event"]
      assert_equal "db-host", payload["hostname"]
      assert_equal 1, payload["databases"].length
      assert_equal "app", payload["databases"].first["database"]
    end

    # --- Trigger matrix ---------------------------------------------------

    def test_notifier_only_fires_for_configured_events
      failure_only = Notify::Webhook.new(url: "https://hook.test/x", events: %w[failure], logger: null_logger)
      stub = stub_request(:post, "https://hook.test/x").to_return(status: 200)

      refute failure_only.notify(success_summary), "should skip success when only on failure"
      assert_not_requested stub

      assert failure_only.notify(failure_summary)
      assert_requested stub
    end

    # --- Webhook ----------------------------------------------------------

    def test_webhook_posts_json_payload
      stub = stub_request(:post, "https://hook.test/generic")
             .with(headers: { "Content-Type" => "application/json" })
             .to_return(status: 200)
      Notify::Webhook.new(url: "https://hook.test/generic", events: %w[success], logger: null_logger)
                     .notify(success_summary)

      assert_requested stub
    end

    def test_webhook_slack_format_sends_text
      body = nil
      stub_request(:post, "https://hooks.slack.test/xyz")
        .to_return(status: 200).tap do |s|
        s.with do |req|
          body = req.body
          true
        end
      end
      Notify::Webhook.new(url: "https://hooks.slack.test/xyz", format: "slack", events: %w[success],
                          logger: null_logger).notify(success_summary)

      assert_includes body, "text"
      assert_includes body, "PgKeeper backup SUCCESS"
    end

    def test_webhook_http_error_is_non_fatal
      stub_request(:post, "https://hook.test/fail").to_return(status: 500)
      hook = Notify::Webhook.new(url: "https://hook.test/fail", events: %w[success], logger: null_logger)

      refute hook.notify(success_summary), "5xx should be caught and reported as not-sent"
    end

    # --- Dead man's switch ------------------------------------------------

    def test_healthcheck_pings_on_success_only_by_default
      stub = stub_request(:get, "https://hc.test/ping").to_return(status: 200)
      hc = Notify::Healthcheck.new(url: "https://hc.test/ping", events: %w[success], logger: null_logger)

      assert hc.notify(success_summary)
      assert_requested stub
      refute hc.notify(failure_summary), "default healthcheck does not fire on failure"
    end

    def test_healthcheck_uses_fail_url_on_failure
      ok = stub_request(:get, "https://hc.test/ok").to_return(status: 200)
      fail = stub_request(:get, "https://hc.test/fail").to_return(status: 200)
      hc = Notify::Healthcheck.new(url: "https://hc.test/ok", fail_url: "https://hc.test/fail",
                                   events: %w[success failure], logger: null_logger)

      hc.notify(success_summary)
      hc.notify(failure_summary)

      assert_requested ok
      assert_requested fail
    end

    # --- Email ------------------------------------------------------------

    def test_email_sends_multipart_message
      Notify::Email.new(to: ["ops@example.com"], from: "pgkeeper@example.com", smtp: {},
                        events: %w[success failure], logger: null_logger).notify(failure_summary)

      delivered = Mail::TestMailer.deliveries

      assert_equal 1, delivered.length
      mail = delivered.first

      assert_equal ["ops@example.com"], mail.to
      assert_includes mail.subject, "FAILURE"
      assert mail.text_part, "has a plain-text part"
      assert mail.html_part, "has an HTML part"
    end

    def test_email_without_recipients_is_non_fatal
      email = Notify::Email.new(to: [], from: "x@example.com", smtp: {}, events: %w[failure], logger: null_logger)

      refute email.notify(failure_summary)
      assert_empty Mail::TestMailer.deliveries
    end

    # --- Factory ----------------------------------------------------------

    def test_build_from_config_assembles_configured_backends
      config = Config.new({
                            "databases" => [{ "name" => "app" }],
                            "notifications" => {
                              "email" => { "to" => ["ops@example.com"], "on" => %w[failure] },
                              "webhook" => { "url" => "https://hook.test/x" },
                              "healthcheck" => { "url" => "https://hc.test/ping" }
                            }
                          })
      notifier = Notify.build(config, logger: null_logger)

      assert_equal 3, notifier.backends.length
    end

    def test_build_with_no_notifications_is_empty
      config = Config.new({ "databases" => [{ "name" => "app" }] })

      refute_predicate Notify.build(config, logger: null_logger), :any?
    end
  end
end
