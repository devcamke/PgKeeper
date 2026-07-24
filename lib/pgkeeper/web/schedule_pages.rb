# frozen_string_literal: true

module PgKeeper
  module Web
    # The Schedule page and its editor endpoint, mixed into {App}: the
    # resolved plan, plus the form that sets or clears `schedule:` keys in
    # the config file through {ScheduleAdmin}.
    module SchedulePages
      private

      def page_schedule(request)
        html render_view("schedule", title: "Schedule",
                                     plan: @dashboard.schedule_plan,
                                     message: presence(request.params["msg"]),
                                     editable: @schedule_admin.editable?,
                                     config_path: @config.source,
                                     global_schedule: @config.schedule,
                                     databases: @config.databases)
      end

      # Browser-only by design (CSRF + confirm; not on the Bearer API): parse
      # the expression, then set or clear the `schedule:` key in the config
      # file — see {ScheduleAdmin} for the full posture.
      def act_set_schedule(request)
        redirect_msg(@schedule_admin.set(request.params).message, path: "/schedule")
      end
    end
  end
end
