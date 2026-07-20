# PgKeeper

A full-fledged, automated PostgreSQL backup solution in Ruby.

PgKeeper dumps your databases on a schedule, compresses and optionally encrypts the
artifacts, stores them locally and/or in the cloud (Google Drive, Dropbox,
SharePoint/OneDrive, S3-compatible), enforces retention policies, verifies that backups
are actually restorable, reports status via email, and includes an optional web dashboard
(`pgkeeper web`) for monitoring backup health and triggering runs.

**Status:** v0.1 (Phases 0–2) is implemented and tested — local dumps with checksummed
manifests, cluster globals, run locking, and an environment `doctor`. See
[PLAN.md](PLAN.md) for the full multi-phase build plan and roadmap.

## What works today (v0.1)

- **`pgkeeper doctor`** — checks that `pg_dump`/`pg_restore`/`pg_dumpall`/`psql` are on
  PATH, validates your config, confirms each database is reachable, and warns on
  `pg_dump`-vs-server version drift.
- **`pgkeeper validate`** — loads the config and reports every schema problem at once.
- **`pgkeeper backup`** — dumps each configured database (custom/plain/directory format),
  optionally captures cluster globals (`pg_dumpall --globals-only`), writes a per-backup
  manifest with a SHA-256 checksum, and lands everything in local storage. Runs are
  guarded by an flock so overlapping cron jobs can't collide, and each dump is written to
  a staging dir and atomically renamed into place — a crash never leaves a half-written
  file that looks complete.
- **`pgkeeper list`** — lists the backups present in local storage with size and age.

Meaningful exit codes throughout: `0` success, `1` partial failure, `2` total failure.

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

## Development

```sh
mise exec -- bundle exec rake test        # unit + integration (integration skips w/o PG)
mise exec -- bundle exec rake test:unit   # fast, hermetic unit tests only
mise exec -- bundle exec rake lint        # RuboCop
```

Integration tests run against a live Postgres when the `PGKEEPER_TEST_PG*` environment
variables point at one (CI supplies a `postgres:16` service container); otherwise they
skip, keeping the unit suite hermetic.
