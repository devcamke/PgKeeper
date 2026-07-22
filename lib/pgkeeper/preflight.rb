# frozen_string_literal: true

require "open3"

module PgKeeper
  # Pre-dump disk-space guard. Refuses to start a dump we probably can't fit,
  # reserving the larger of a fixed floor and a multiple of the live database
  # size. The multiple covers the staged pipeline, where the raw dump and its
  # compressed/encrypted copy briefly coexist on disk.
  #
  # When the size can't be measured (psql missing, no permission, server
  # unreachable) it falls back to the floor rather than blocking the run on a
  # number it doesn't have.
  class Preflight
    def initialize(min_free_bytes:, scratch_factor: 1.5)
      @min_free_bytes = min_free_bytes
      @scratch_factor = scratch_factor
    end

    # Raise {PreflightError} unless +dir+ has room for a dump of +db+. A nil
    # free-space reading (df unavailable) is treated as "can't tell, don't
    # block".
    def check!(db, dir)
      free = free_bytes(dir)
      return if free.nil?

      needed = required_bytes(db)
      return if free >= needed

      raise PreflightError,
            "insufficient free space at #{dir}: #{human_bytes(free)} free, need ~#{human_bytes(needed)} " \
            "for #{db.name}. Free up space or point `workdir:` at a larger volume."
    end

    private

    def required_bytes(db)
      estimate = estimated_database_bytes(db)
      return @min_free_bytes if estimate.nil?

      [@min_free_bytes, (estimate * @scratch_factor).ceil].max
    end

    # Live on-disk size of the database via +pg_database_size+ — a conservative
    # upper bound on the dump, which drops bloat and stores indexes as DDL rather
    # than data. Returns nil when psql is unavailable or the query fails.
    def estimated_database_bytes(db)
      # capture2e keeps psql's connection errors out of the operator's terminal;
      # on failure the status is non-zero and we bail before parsing.
      out, status = Open3.capture2e(db.libpq_env, "psql", "-XtAc",
                                    "SELECT pg_database_size(current_database())")
      return nil unless status.success?

      value = out.strip
      value.match?(/\A\d+\z/) ? Integer(value) : nil
    rescue StandardError
      nil
    end

    def free_bytes(path)
      out, status = Open3.capture2("df", "-Pk", path)
      return nil unless status.success?

      Integer(out.lines[1].split[3]) * 1024
    rescue StandardError
      nil
    end

    def human_bytes(bytes)
      units = %w[B KB MB GB TB]
      size = bytes.to_f
      unit = 0
      while size >= 1024 && unit < units.length - 1
        size /= 1024
        unit += 1
      end
      format("%<n>.1f%<u>s", n: size, u: units[unit])
    end
  end
end
