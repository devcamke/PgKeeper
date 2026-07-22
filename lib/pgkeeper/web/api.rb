# frozen_string_literal: true

require "json"

module PgKeeper
  module Web
    # The remote-trigger JSON API, mixed into {App}. Splitting it out keeps the
    # HTML dashboard and the machine API as two small surfaces.
    #
    # Actions are the same background jobs the browser starts, so a remote
    # trigger can never do anything a dashboard click couldn't — it just skips
    # the browser-only guards. Authentication is already handled by the {Auth}
    # middleware; requiring the credential to arrive as a *Bearer* token (not
    # browser basic-auth) is what stands in for CSRF here, since a cross-site
    # browser request cannot attach an Authorization header. Each POST starts a
    # job and returns its id (HTTP 202) so callers poll GET /api/jobs/:id.
    #
    # Relies on the host object's @jobs, @actions, @config and the
    # json_response / presence / presence_list / backup_label helpers.
    module Api
      def dispatch_api_post(request)
        unless bearer?(request)
          return api_error(403, "API actions require a Bearer token (Authorization: Bearer <token>)")
        end

        body = json_body(request)
        @logger.info("api action requested", caller: caller_name(request), action: request.path_info)
        case request.path_info
        when "/api/actions/backup" then api_backup(request, body)
        when "/api/actions/verify" then api_verify(request, body)
        when "/api/actions/prune" then api_prune(request, body)
        else api_error(404, "unknown API action")
        end
      end

      # The authenticated caller recorded by the Auth middleware (a token name
      # or basic-auth username), for audit lines. "unknown" when the app is
      # driven without the middleware (tests) or the key is absent.
      def caller_name(request)
        presence(request.get_header(Auth::CALLER_KEY)) || "unknown"
      end

      def api_backup(request, body)
        only = presence(body["database"] || request.params["database"])&.then { |name| [name] }
        destinations = presence_list(body["destinations"] || request.params["destinations"])
        api_job(backup_label(only, destinations)) { @actions.backup(only: only, destinations: destinations) }
      end

      def api_verify(request, body)
        deep = truthy?(body.fetch("deep", request.params["deep"]))
        api_job(deep ? "verify --deep" : "verify") { @actions.verify(deep: deep) }
      end

      def api_prune(request, body)
        apply = truthy?(body.fetch("apply", request.params["apply"]))
        api_job(apply ? "prune --apply" : "prune (dry run)") { @actions.prune(apply: apply) }
      end

      # Start a background job and return its descriptor with 202 Accepted.
      def api_job(action, &)
        job = @jobs.run(action, &)
        json_response({ "job" => job_json(job) }, status: 202)
      end

      def api_job_status(id)
        job = @jobs.find(id)
        return api_error(404, "no such job: #{id}") if job.nil?

        json_response({ "job" => job_json(job) })
      end

      def api_destinations
        rows = @config.destinations.map { |d| { "token" => d.token, "label" => d.label, "type" => d.type } }
        { "destinations" => rows }
      end

      def job_json(job)
        {
          "id" => job.id, "action" => job.action, "status" => job.status.to_s,
          "detail" => job.detail, "started_at" => job.started_at&.iso8601,
          "finished_at" => job.finished_at&.iso8601
        }
      end

      # Whether the credential arrived as a Bearer token. Presence of the scheme
      # is enough: the Auth middleware already validated the token itself.
      def bearer?(request)
        request.get_header("HTTP_AUTHORIZATION").to_s.strip.downcase.start_with?("bearer ")
      end

      # Parse a JSON request body into a Hash, tolerating an empty or non-JSON
      # body (form-encoded callers fall back to request.params). Rewinds so a
      # later reader sees the whole body.
      def json_body(request)
        return {} unless request.media_type == "application/json"

        raw = request.body.read
        request.body.rewind
        return {} if raw.to_s.empty?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def truthy?(value)
        ["on", "true", "1", "yes", true, 1].include?(value)
      end

      def api_error(status, message)
        [status, { "content-type" => "application/json" }, [JSON.generate("error" => message)]]
      end
    end
  end
end
