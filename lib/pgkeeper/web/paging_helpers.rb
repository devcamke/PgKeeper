# frozen_string_literal: true

module PgKeeper
  module Web
    # Renders the pager row under the Runs and Backups tables. Mixed into
    # {ViewHelpers} so every view can call it.
    module PagingHelpers
      # A pager row: newer/older links plus "page X of Y · N <unit>". +state+
      # carries +:page+/+:pages+/+:total+, an optional +:key+ (the query param
      # the links set — nested keys like +page[nas]+ page one table without
      # resetting another), and an optional +:query+ of params to preserve
      # across pages.
      def pager(path:, unit:, state:)
        page = state.fetch(:page)
        pages = state.fetch(:pages)
        return "" if pages <= 1

        info = %(<span class="muted">page #{page} of #{pages} · #{state.fetch(:total)} #{h(unit)}</span>)
        newer = pager_link(path, state, page - 1, "&lsaquo; newer", page > 1)
        older = pager_link(path, state, page + 1, "older &rsaquo;", page < pages)
        %(<div class="pager">#{newer} #{info} #{older}</div>)
      end

      private

      def pager_link(path, state, target, label, enabled)
        return %(<span class="pager-off">#{label}</span>) unless enabled

        query = (state[:query] || {}).reject { |_, v| v.nil? || v.to_s.empty? }
        params = query.merge(state.fetch(:key, "page") => target)
        qs = params.map { |k, v| "#{u(k)}=#{u(v)}" }.join("&amp;")
        %(<a href="#{h(path)}?#{qs}">#{label}</a>)
      end
    end
  end
end
