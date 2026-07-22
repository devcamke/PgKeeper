# PgKeeper

A full-fledged, automated PostgreSQL backup solution in Ruby.

PgKeeper dumps your databases on a schedule, compresses and optionally encrypts the
artifacts, stores them locally and/or in the cloud (S3-compatible object storage, Dropbox,
and Google Drive), enforces retention policies, verifies that backups are actually
restorable, reports status via email, and includes an optional web dashboard (`pgkeeper
web`) for monitoring backup health and triggering runs.

**Status:** v1.0 (Phases 0–10) is implemented and tested — backups are compressed,
optionally encrypted, fanned out to multiple destinations, pruned by a retention policy,
**verifiably restorable**, **reported on** (run-history, email/webhook alerts, dead-man's
switch), **scheduled** (cron/systemd installers or a built-in daemon), **observable in a
browser** (`pgkeeper web`), and **deployable with Docker**. See [PLAN.md](PLAN.md) for the
full multi-phase build plan, [CHANGELOG.md](CHANGELOG.md) for what shipped when, and
[docs/RESTORE.md](docs/RESTORE.md) for the restore runbook.

> **Known gap (by design, documented):** PgKeeper takes logical dumps — there is no WAL
> archiving / point-in-time recovery, so a restore loses everything since the last dump.
> Schedule accordingly; PITR guidance is on the post-v1 backlog (PLAN.md Phase 11).

## What works today

- **`pgkeeper doctor`** — checks that `pg_dump`/`pg_restore`/`pg_dumpall`/`psql` are on
  PATH, validates your config, health-checks every storage destination, confirms each
  database is reachable, and warns on `pg_dump`-vs-server version drift.
- **`pgkeeper validate`** — loads the config and reports every schema problem at once.
- **`pgkeeper backup`** — for each database, runs the full pipeline:

      pg_dump → package (directory formats) → compress → encrypt → manifest
              → fan out to every configured destination

  - **Compression:** gzip, zip, or zstd; skipped automatically for already-compressed
    `custom`/`directory` dumps.
  - **Encryption at rest:** AES-256-GCM (built in) or GPG, keyed by passphrase or keyfile;
    tamper-evident, and reversed transparently on restore.
  - **Storage fan-out:** local filesystem, S3-compatible object storage (AWS S3, MinIO,
    Backblaze B2, Cloudflare R2, Spaces), Dropbox, and Google Drive. Destinations are
    independent — one being down fails only that destination, and the report shows
    per-destination status.
  - Cluster globals (`pg_dumpall --globals-only`), a SHA-256 manifest per artifact,
    flock-guarded runs, and staging + atomic finalize so a crash never leaves a
    half-written backup.
- **`pgkeeper list`** — lists backups across every destination with size, age, the
  compression/encryption pipeline, and verification status.
- **`pgkeeper prune`** — enforces the retention policy (`keep_last` and/or GFS
  daily/weekly/monthly/yearly), per destination and per database. Dry-run by default;
  `--apply` to delete. Safety rails: never deletes the newest backup, never prunes to
  zero, never deletes anything newer than the last verified backup.
- **`pgkeeper verify [--deep]`** — Tier 1 re-checksums the artifact, Tier 2 proves it's a
  readable archive (`pg_restore --list` / non-empty SQL), and `--deep` restores it into a
  throwaway scratch database. Passing marks the backup verified.
- **`pgkeeper restore`** — fetches a backup from a destination, reverses the
  encryption + compression pipeline, and restores into a target database via
  `pg_restore`/`psql`. Overwriting a non-empty database requires `--force`. See
  [docs/RESTORE.md](docs/RESTORE.md).
- **`pgkeeper status`** — reads the SQLite run-history and shows the most recent backup
  per database (status, age, size), or recent runs for one database with `--database`.
- **Notifications** (fired automatically after each run, and testable with
  `pgkeeper test-notification`): **email** (SMTP+TLS, HTML+text, success/failure
  triggers), a generic/Slack **webhook**, and a **dead-man's-switch** ping so a monitor
  catches a cron that silently never ran. Notifier failures are logged and never affect
  the backup itself.
- **Scheduling** — set a `schedule:` (cron, natural language, or shorthands like
  `daily at 03:15`), globally or per-database. `pgkeeper schedule install` emits
  **flock-guarded crontab lines** or **systemd service+timer units** (with
  `RandomizedDelaySec` stagger and `Persistent=true` catch-up); `pgkeeper schedule print`
  shows the resolved plan. For containers without cron/systemd, `pgkeeper daemon` runs the
  schedules in-process with jitter.

- **`pgkeeper web`** — the optional monitoring dashboard:
  - **Overview**: per-database traffic lights (last run, last verified age, next scheduled
    run), size-trend sparklines that make a suddenly-smaller dump visible, and a
    per-destination health grid.
  - **Runs**: timeline of every recorded run with a detail page per run (duration,
    per-destination status, stderr on failures).
  - **Retention**: the policy and exactly what the next prune would delete.
  - **Backups**: browse artifacts across destinations and download them (allowlisted
    against the catalog — the endpoint can't be steered at arbitrary paths).
  - **Actions**: trigger backup / verify / prune / test-notification / doctor from the
    browser. Every action needs a CSRF token plus an explicit confirmation, and runs
    through the same lock as cron — never a second concurrent pipeline. Restores are
    deliberately CLI-only.
  - **JSON API**: `/api/status` and `/api/runs` for external monitors.
  - **Security**: auth is mandatory (constant-time token or basic auth), it binds to
    `127.0.0.1` by default, and it reads the same run-history/manifests the CLI writes —
    no second data path. Needs the optional `rack` + `puma` gems; see the `web:` block in
    the example config and [docs/SECURITY.md](docs/SECURITY.md).

Meaningful exit codes throughout: `0` success, `1` partial (some destinations/databases
failed), `2` total failure. Every run is recorded to a SQLite history store that powers
`status` and the dashboard.

Storage adapters share one contract (upload / download / list / delete / healthcheck with
retry + backoff), so local, S3, and the in-memory test backend are provably
interchangeable. Cloud SDKs are optional dependencies, lazy-loaded only when used.

## Stack

- Ruby 4 (toolchain pinned with [mise](https://mise.jdx.dev); see `.mise.toml`)
- Gem-packaged CLI built on `thor`
- `pg_dump` / `pg_restore` under the hood (never reimplemented)
- Minitest for testing — unit tests plus Dockerized/live-Postgres integration tests

## Getting started

```sh
# 1. Provision the pinned Ruby toolchain and install dependencies.
mise install
mise exec -- bundle install

# 2. Write a config (copy the example and edit).
cp config/pgkeeper.example.yml pgkeeper.yml
export PGKEEPER_APP_PASSWORD=...        # secrets come from the environment

# 3. Check the environment, then take a backup.
mise exec -- ruby -Ilib bin/pgkeeper doctor  -c pgkeeper.yml
mise exec -- ruby -Ilib bin/pgkeeper backup  -c pgkeeper.yml
mise exec -- ruby -Ilib bin/pgkeeper list    -c pgkeeper.yml
```

Config is a single declarative YAML file with ERB interpolation for secrets, so
passwords stay in the environment and out of git:

```yaml
databases:
  - name: app_production
    host: db.internal
    username: backup_user
    password: <%= ENV["PGKEEPER_APP_PASSWORD"] %>
    format: custom
    include_globals: true
storage:
  - type: local
    path: /var/backups/pgkeeper/backups
```

See [`config/pgkeeper.example.yml`](config/pgkeeper.example.yml) for the full annotated
schema.

## Docker

The image bundles the CLI, the scheduling daemon, and the dashboard (plus the
S3 SDK and `postgresql-client`):

```sh
docker build -t pgkeeper .
docker run --rm -v ./pgkeeper.yml:/etc/pgkeeper/pgkeeper.yml:ro pgkeeper doctor

# Daemon + dashboard together, wired next to a database:
cp docker-compose.example.yml docker-compose.yml   # then edit
export POSTGRES_PASSWORD=... PGKEEPER_APP_PASSWORD=... PGKEEPER_WEB_TOKEN=...
docker compose up -d
```

## Documentation

- [docs/USAGE.md](docs/USAGE.md) — **the full usage guide**: install, configure,
  every command, scheduling, dashboard, Docker, library use, troubleshooting.
- [docs/RESTORE.md](docs/RESTORE.md) — the 3 a.m. restore runbook.
- [docs/SECURITY.md](docs/SECURITY.md) — least-privilege backup role, secrets,
  encryption, dashboard hardening.
- [docs/PROVIDERS.md](docs/PROVIDERS.md) — storage setup for AWS S3, MinIO,
  Backblaze B2, Cloudflare R2, Spaces.
- [CHANGELOG.md](CHANGELOG.md) — release history mapped to plan phases.

## Development

```sh
mise exec -- bundle exec rake test        # unit + integration (integration skips w/o PG)
mise exec -- bundle exec rake test:unit   # fast, hermetic unit tests only
mise exec -- bundle exec rake lint        # RuboCop
```

Integration tests run against a live Postgres when the `PGKEEPER_TEST_PG*` environment
variables point at one (CI supplies a `postgres:16` service container); otherwise they
skip, keeping the unit suite hermetic.
