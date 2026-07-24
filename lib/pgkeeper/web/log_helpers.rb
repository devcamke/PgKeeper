# frozen_string_literal: true

module PgKeeper
  module Web
    # Level parsing for the Logs page — shared by the route (filtering) and the
    # view (colorizing), and mixed into {ViewHelpers}.
    module LogHelpers
      LOG_LEVELS = %w[debug info warn error fatal].freeze

      # The level of one structured log line — logfmt (+level=warn+) or JSON
      # (+"level":"warn"+) — or nil for anything unparseable. A line that
      # doesn't parse still renders, just unstyled.
      def log_line_level(line)
        match = line.match(/(?:^|\s)level=(\w+)/) || line.match(/"level"\s*:\s*"(\w+)"/)
        level = match && match[1].downcase
        LOG_LEVELS.include?(level) ? level : nil
      end
      module_function :log_line_level
      public :log_line_level
    end
  end
end
