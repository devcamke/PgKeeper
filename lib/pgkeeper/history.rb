# frozen_string_literal: true

require "sqlite3"
require "json"
require "fileutils"
require "time"

module PgKeeper
  # A single-file SQLite store of past runs — one row per database per run. It
  # powers `pgkeeper status` now and feeds the web dashboard later, reading the
  # same data the CLI writes so the two can never drift apart.
  #
  # Recording is best-effort: a history write must never take down a backup that
  # otherwise succeeded, so {#record} swallows and logs its own errors.
  class History
    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS runs (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id          TEXT NOT NULL,
        database        TEXT NOT NULL,
        status          TEXT NOT NULL,
        started_at      TEXT NOT NULL,
        finished_at     TEXT,
        duration_seconds REAL,
        artifact_count  INTEGER DEFAULT 0,
        total_bytes     INTEGER DEFAULT 0,
        destinations    TEXT,
        error           TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_runs_db_time ON runs (database, started_at);
    SQL

    Row = Struct.new(:run_id, :database, :status, :started_at, :finished_at,
                     :duration_seconds, :artifact_count, :total_bytes, :destinations, :error,
                     keyword_init: true) do
      def success? = status == "success"
      def failure? = status == "failure"
    end

    attr_reader :path

    def initialize(path, logger: PgKeeper.logger)
      @path = path
      @logger = logger
    end

    # Record every database result of a run. Never raises — a failed history
    # write is logged, not propagated.
    def record(report, run_id:, started_at:, finished_at:)
      with_db do |db|
        report.results.each { |result| insert_row(db, result, run_id, started_at, finished_at) }
      end
      true
    rescue StandardError => e
      @logger.warn("history record failed", error: e.message)
      false
    end

    # The most recent run row for each database, newest first.
    def last_per_database
      rows = query(<<~SQL)
        SELECT r.* FROM runs r
        JOIN (SELECT database, MAX(started_at) AS mx FROM runs GROUP BY database) latest
          ON r.database = latest.database AND r.started_at = latest.mx
        ORDER BY r.database
      SQL
      rows.map { |h| to_row(h) }
    end

    # Every row recorded under one run id (one row per database), in insertion
    # order. Powers the dashboard's run-detail page.
    def runs_for(run_id)
      query("SELECT * FROM runs WHERE run_id = ? ORDER BY id", [text_param(run_id)]).map { |h| to_row(h) }
    end

    # Total-bytes of the most recent successful runs for one database, newest
    # first. Feeds backup-size anomaly detection; skips zero/failed runs so the
    # baseline reflects real dumps only.
    def recent_success_sizes(database, limit: 5)
      rows = query(<<~SQL, [text_param(database), limit])
        SELECT total_bytes FROM runs
        WHERE database = ? AND status = 'success' AND total_bytes > 0
        ORDER BY started_at DESC, id DESC LIMIT ?
      SQL
      rows.map { |h| h["total_bytes"].to_i }
    end

    # The most recent +limit+ rows, optionally for one database.
    def recent(limit: 20, database: nil)
      sql = +"SELECT * FROM runs"
      params = []
      if database
        sql << " WHERE database = ?"
        params << text_param(database)
      end
      sql << " ORDER BY started_at DESC, id DESC LIMIT ?"
      params << limit
      query(sql, params).map { |h| to_row(h) }
    end

    private

    def insert_row(db, result, run_id, started_at, finished_at)
      artifacts = result.respond_to?(:artifacts) ? Array(result.artifacts) : []
      db.execute(<<~SQL, insert_params(result, run_id, started_at, finished_at, artifacts))
        INSERT INTO runs (run_id, database, status, started_at, finished_at,
                          duration_seconds, artifact_count, total_bytes, destinations, error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end

    def insert_params(result, run_id, started_at, finished_at, artifacts)
      [
        run_id, result.database, result.status.to_s,
        started_at.iso8601, finished_at.iso8601, result.duration_seconds,
        artifacts.length, artifacts.sum { |a| a[:size_bytes].to_i },
        JSON.generate(destination_summary(artifacts)), result.error&.message
      ]
    end

    def destination_summary(artifacts)
      artifacts.flat_map { |a| Array(a[:destinations]) }
               .map { |d| { "name" => d.name, "status" => d.status.to_s } }
               .uniq
    end

    def with_db
      FileUtils.mkdir_p(File.dirname(@path))
      db = SQLite3::Database.new(@path)
      db.busy_timeout = 5000
      db.execute_batch(SCHEMA)
      yield db
    ensure
      db&.close
    end

    def query(sql, params = [])
      results = nil
      with_db do |db|
        db.results_as_hash = true
        results = db.execute(sql, params)
      end
      results || []
    end

    def to_row(hash)
      Row.new(
        run_id: hash["run_id"], database: hash["database"], status: hash["status"],
        started_at: hash["started_at"], finished_at: hash["finished_at"],
        duration_seconds: hash["duration_seconds"], artifact_count: hash["artifact_count"],
        total_bytes: hash["total_bytes"], error: hash["error"],
        destinations: parse_json(hash["destinations"])
      )
    end

    def parse_json(value)
      value ? JSON.parse(value) : []
    rescue JSON::ParserError
      []
    end

    # sqlite3 binds an ASCII-8BIT string as a BLOB, which never equals a TEXT
    # column — and strings sliced out of a Rack PATH_INFO are binary-encoded.
    # Normalize query parameters to UTF-8 so lookups match what was written.
    def text_param(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8)
    end
  end
end
