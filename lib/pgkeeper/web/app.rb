# frozen_string_literal: true

require "erb"
require "json"
require "openssl"
require "securerandom"

require "pgkeeper/web/api"
require "pgkeeper/web/downloads"
require "pgkeeper/web/view_helpers"

module PgKeeper
  module Web
    # The dashboard's Rack application: routing, CSRF enforcement, page
    # rendering (stdlib ERB), the JSON API ({Api}), and the
    # catalog-allowlisted artifact download endpoints ({Downloads}).
    # Authentication happens before any request reaches this class —
    # see {Auth}.
    class App
      include Api
      include Downloads

      VIEWS = File.expand_path("views", __dir__)

      attr_reader :jobs, :csrf_token

      def initialize(config, logger: PgKeeper.logger, actions: nil, connections: nil)
        @config = config
        @logger = logger
        @dashboard = Dashboard.new(config, logger: logger)
        @connections = connections || Connections.new(config, logger: logger)
        @database_admin = DatabaseAdmin.new(config, connections: @connections, logger: logger)
        @actions = actions || Actions.new(config, logger: logger)
        @jobs = Jobs.new(logger: logger)
        # One CSRF token per app boot: rotating per-request would need session
        # state, and every request is already authenticated before it gets here.
        @csrf_token = SecureRandom.hex(32)
      end

      def call(env)
        request = Rack::Request.new(env)
        dispatch(request)
      rescue StandardError => e
        @logger.error("dashboard request failed", path: env["PATH_INFO"], error: e.message,
                                                  error_class: e.class.name)
        [500, { "content-type" => "text/plain" }, ["500 Internal Server Error\n"]]
      end

      private

      def dispatch(request)
        case request.request_method
        when "GET", "HEAD" then dispatch_get(request)
        when "POST" then dispatch_post(request)
        else [405, { "content-type" => "text/plain", "allow" => "GET, HEAD, POST" }, ["405 Method Not Allowed\n"]]
        end
      end

      def dispatch_get(request)
        case request.path_info
        when "/" then page_overview
        when "/runs" then page_runs(request)
        when %r{\A/runs/([^/]+)\z} then page_run(Regexp.last_match(1))
        when "/connections" then page_connections(request)
        when "/retention" then page_retention
        when "/schedule" then page_schedule
        when "/backups" then page_backups
        when "/actions" then page_actions(request)
        else dispatch_get_download(request)
        end
      end

      def dispatch_get_download(request)
        case request.path_info
        when "/download" then download(request)
        when "/download-set" then download_set(request)
        else dispatch_get_data(request)
        end
      end

      # Machine-readable read endpoints (JSON API + Prometheus metrics), split
      # out from the HTML pages to keep either route table small.
      def dispatch_get_data(request)
        case request.path_info
        when "/api/status" then json_response(@dashboard.api_status)
        when "/api/runs" then api_runs(request)
        when "/api/destinations" then json_response(api_destinations)
        when "/api/connections" then json_response(api_connections)
        when "/api/jobs" then json_response({ "jobs" => @jobs.all.map { |j| job_json(j) } })
        when %r{\A/api/jobs/(\d+)\z} then api_job_status(Regexp.last_match(1).to_i)
        when "/metrics" then metrics_response
        else not_found
        end
      end

      # Prometheus exposition of backup state, behind the same auth as the rest
      # of the dashboard (scrapers pass the token as a bearer credential).
      def metrics_response
        [200, { "content-type" => Metrics::CONTENT_TYPE }, [Metrics.render(@config, logger: @logger)]]
      end

      # POST splits two ways. The JSON action API (/api/actions/*) is for remote
      # triggering — scripts, webhooks, a phone shortcut — and is guarded by the
      # Bearer token alone. The HTML form routes are for the browser and require
      # the CSRF token plus an explicit confirmation checkbox, so a stray click
      # or a forged cross-site form can never start anything.
      def dispatch_post(request)
        return dispatch_api_post(request) if request.path_info.start_with?("/api/")

        return forbidden("invalid or missing CSRF token") unless csrf_ok?(request)
        unless confirmed?(request)
          return redirect_msg("confirmation checkbox is required — nothing was started",
                              path: flash_path(request))
        end

        @logger.info("dashboard action requested", caller: caller_name(request), action: request.path_info)
        case request.path_info
        when "/actions/backup" then act_backup(request)
        when "/actions/verify" then act_verify(request)
        when "/actions/prune" then act_prune(request)
        when "/actions/test-notification" then act("test-notification") { @actions.test_notification }
        when "/actions/doctor" then act("doctor") { @actions.doctor }
        when "/connections/add" then act_add_database(request)
        else not_found
        end
      end

      # -- pages -------------------------------------------------------------

      def page_overview
        html render_view("overview", title: "Overview",
                                     databases: @dashboard.overview_rows,
                                     destinations: @dashboard.destination_rows,
                                     pitr: @dashboard.pitr_rows,
                                     recent: @dashboard.recent_runs(limit: 10))
      end

      def page_runs(request)
        database = presence(request.params["database"])
        limit = (request.params["limit"] || 50).to_i.clamp(1, 500)
        html render_view("runs", title: "Runs",
                                 runs: @dashboard.recent_runs(database: database, limit: limit),
                                 database: database,
                                 database_names: @config.databases.map(&:name))
      end

      def page_run(run_id)
        rows = @dashboard.run_detail(run_id)
        return not_found if rows.empty?

        html render_view("run", title: "Run #{run_id}", run_id: run_id, rows: rows)
      end

      def page_connections(request)
        html render_view("connections", title: "Connections",
                                        message: presence(request.params["msg"]),
                                        databases: @connections.database_rows,
                                        clusters: @connections.cluster_rows,
                                        destinations: @dashboard.destination_rows,
                                        editable: @database_admin.editable?,
                                        config_path: @config.source)
      end

      # Browser-only by design (CSRF + confirm; not on the Bearer API): probe
      # the submitted details, then append the entry to the config file — see
      # {DatabaseAdmin} for the full posture.
      def act_add_database(request)
        result = @database_admin.add(request.params)
        redirect_msg(result.message, path: "/connections")
      end

      def page_retention
        html render_view("retention", title: "Retention",
                                      policy: @config.retention,
                                      preview: @dashboard.retention_preview)
      end

      def page_schedule
        html render_view("schedule", title: "Schedule", plan: @dashboard.schedule_plan)
      end

      def page_backups
        html render_view("backups", title: "Backups", destinations: @dashboard.sets_by_destination)
      end

      def page_actions(request)
        html render_view("actions", title: "Actions",
                                    message: presence(request.params["msg"]),
                                    database_names: @config.databases.map(&:name),
                                    destinations: @config.destinations,
                                    jobs: @jobs.all)
      end

      def api_runs(request)
        json_response @dashboard.api_runs(
          database: presence(request.params["database"]),
          limit: (request.params["limit"] || 50).to_i.clamp(1, 500)
        )
      end

      # -- management actions ------------------------------------------------

      def act_backup(request)
        only = presence(request.params["database"])&.then { |name| [name] }
        destinations = presence_list(request.params["destinations"])
        act(backup_label(only, destinations)) { @actions.backup(only: only, destinations: destinations) }
      end

      def backup_label(only, destinations)
        parts = ["backup"]
        parts << only.first if only
        parts << "→ #{destinations.join(',')}" if destinations
        parts.join(" ")
      end

      def act_verify(request)
        deep = request.params["deep"] == "on"
        act(deep ? "verify --deep" : "verify") { @actions.verify(deep: deep) }
      end

      def act_prune(request)
        apply = request.params["apply"] == "on"
        act(apply ? "prune --apply" : "prune (dry run)") { @actions.prune(apply: apply) }
      end

      def act(action, &)
        job = @jobs.run(action, &)
        redirect_msg("started #{action} (job ##{job.id})")
      end

      # -- plumbing ----------------------------------------------------------

      def csrf_ok?(request)
        token = request.params["_csrf"].to_s
        !token.empty? && OpenSSL.fixed_length_secure_compare(
          OpenSSL::Digest.digest("SHA256", token), OpenSSL::Digest.digest("SHA256", @csrf_token)
        )
      end

      def confirmed?(request)
        request.params["confirm"] == "on"
      end

      def render_view(name, title:, **assigns)
        content = render_erb(name, assigns)
        render_erb("layout", { title: title, content: content, active: name })
      end

      def render_erb(name, assigns)
        # Read as UTF-8 explicitly: the templates contain non-ASCII glyphs (→, —,
        # status icons), and ERB compiles them into Ruby source. Relying on the
        # process's default external encoding would break rendering under a
        # non-UTF-8 locale (e.g. LANG=C).
        template = File.read(File.join(VIEWS, "#{name}.erb"), encoding: "UTF-8")
        ERB.new(template,
                trim_mode: "-").result(ViewContext.new(assigns.merge(csrf_token: @csrf_token)).binding_for_erb)
      end

      # The object ERB templates evaluate against: assigns become instance
      # variables, formatting comes from {ViewHelpers}.
      class ViewContext
        include ViewHelpers

        def initialize(assigns)
          assigns.each { |key, value| instance_variable_set(:"@#{key}", value) }
        end

        def binding_for_erb = binding
      end

      def html(body, status: 200)
        [status, { "content-type" => "text/html; charset=utf-8" }, [body]]
      end

      def json_response(payload, status: 200)
        [status, { "content-type" => "application/json" }, [JSON.generate(payload)]]
      end

      def redirect_msg(message, path: "/actions")
        [303, { "location" => "#{path}?msg=#{Rack::Utils.escape(message)}" }, []]
      end

      # Which page a POST's flash should land on: forms under /connections
      # flash there, everything else on the Actions page.
      def flash_path(request)
        request.path_info.start_with?("/connections") ? "/connections" : "/actions"
      end

      def not_found
        [404, { "content-type" => "text/plain" }, ["404 Not Found\n"]]
      end

      def forbidden(reason)
        [403, { "content-type" => "text/plain" }, ["403 Forbidden: #{reason}\n"]]
      end

      def presence(value)
        value.nil? || value.to_s.empty? ? nil : value.to_s
      end

      # Normalize a destination selector param — an array (checkboxes), a
      # comma-separated string, or nil — into an array of tokens, or nil for
      # "all destinations".
      def presence_list(value)
        list = Array(value).flat_map { |v| v.to_s.split(",") }.map(&:strip).reject(&:empty?)
        list.empty? ? nil : list
      end
    end
  end
end
