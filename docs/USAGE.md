# PgKeeper Usage Guide

Everything you need to run PgKeeper day to day: installation, configuration,
every command, scheduling, the web dashboard, and troubleshooting.

Companion documents:

- [RESTORE.md](RESTORE.md) — the step-by-step restore runbook (read it *before*
  you need it).
- [SECURITY.md](SECURITY.md) — least-privilege database role, secret handling,
  encryption, dashboard hardening.
- [PROVIDERS.md](PROVIDERS.md) — storage backend setup (AWS S3, MinIO,
  Backblaze B2, Cloudflare R2, Spaces).

---

## 1. What PgKeeper does

For every configured database, a backup run executes this pipeline:

```
pg_dump → package → compress → encrypt → manifest → fan out to every storage
                                                    destination independently
```

Around that pipeline it provides scheduling (cron / systemd / built-in
daemon), retention pruning with safety rails, three tiers of verification
(including a real scratch-database restore), guided restores, run history,
notifications (email / webhook / dead-man's switch), and an optional web
dashboard.

**Pick your recovery mode.** By default PgKeeper takes *logical dumps*: a
restore recovers to the moment of the last backup, so choose a backup frequency
that matches how much data you can afford to lose. For a tighter recovery point,
turn on native **point-in-time recovery** (a `clusters:` entry with
`pitr.enabled`): physical base backups plus continuous WAL archiving recover a
whole cluster to any instant in the retained window (RPO in seconds-to-minutes).
See [RPO-RTO.md](RPO-RTO.md) and [PITR-DESIGN.md](PITR-DESIGN.md). *(A
PgKeeper-supervised `pg_receivewal` streamer is still on the roadmap; for stream
mode, run `pg_receivewal` yourself and PgKeeper ships the spool.)*

## 2. Requirements

- Ruby ≥ 3.2 (the repo pins 4.0.6 via [mise](https://mise.jdx.dev) for
  development).
- PostgreSQL client tools on PATH: `pg_dump`, `pg_restore`, `pg_dumpall`,
  `psql` — **at least as new as the servers you back up**.
- Optional, per feature:
  - `zstd` binary for zstd compression; `gpg` for GPG encryption.
  - `aws-sdk-s3` gem for S3-compatible storage.
  - `rack` + `puma` gems for the web dashboard.

`pgkeeper doctor` checks all of this for you.

## 3. Installation

**From source (gem):**

```sh
git clone https://github.com/devcamke/PgKeeper && cd PgKeeper
gem build pgkeeper.gemspec
gem install pgkeeper-*.gem
pgkeeper version
```

**In a Ruby app's Gemfile:**

```ruby
gem "pgkeeper", git: "https://github.com/devcamke/PgKeeper"
```

**Docker:** see [§10](#10-docker) — the image bundles the client tools, the
S3 SDK, and the dashboard.

## 4. Quickstart: first backup in five minutes

```sh
# 1. Write a config. The wizard tests the connection, sets a schedule, and
#    writes pgkeeper.yml for you (it prints the password env var to export):
pgkeeper connect
#    ...or start from the annotated example and edit it by hand:
# cp config/pgkeeper.example.yml pgkeeper.yml
# $EDITOR pgkeeper.yml                     # databases, storage path, schedule

# 2. Secrets come from the environment (the config interpolates ENV via ERB).
export PGKEEPER_APP_PASSWORD=...

# 3. Verify the host can actually take a backup.
pgkeeper doctor

# 4. Take one, look at it, verify it.
pgkeeper backup
pgkeeper list
pgkeeper verify
```

PgKeeper looks for its config at `./pgkeeper.yml`, `./config/pgkeeper.yml`,
then `/etc/pgkeeper/pgkeeper.yml`; use `-c PATH` anywhere to point elsewhere.

## 5. Configuration

One YAML file drives everything. It is rendered with ERB first, so any value
can come from the environment: `password: <%= ENV["PGKEEPER_APP_PASSWORD"] %>`.
Validation is strict — unknown keys, missing required fields, and bad enum
values are all reported at once, before anything touches a database
(`pgkeeper validate` runs just the validation).

```yaml
workdir: /var/backups/pgkeeper     # staging, lock file, run history
schedule: daily at 03:15           # global; per-database schedule overrides

defaults:                          # applied to every database unless overridden
  host: localhost
  port: 5432
  username: backup_user
  format: custom
  include_globals: true

databases:
  - name: app_production           # unique name; also the default DB name
    password: <%= ENV["PGKEEPER_APP_PASSWORD"] %>
  - name: analytics
    format: directory              # parallel dump/restore for large DBs
    exclude_tables: [events_raw]
    schedule: "0 */6 * * *"        # this DB backs up every 6 hours instead

compression: gzip                  # none | gzip | zip | zstd
encryption:
  enabled: true
  type: aes256gcm                  # aes256gcm (built in) | gpg
  passphrase_env: PGKEEPER_ENCRYPTION_PASSPHRASE

storage:                           # every run fans out to ALL targets
  - type: local
    path: /var/backups/pgkeeper/backups
  - type: s3                       # see docs/PROVIDERS.md
    bucket: myapp-backups
    region: us-east-1

retention:                         # enforced per destination, per database
  keep_daily: 7
  keep_weekly: 4
  keep_monthly: 6

notifications:
  email:
    to: [ops@example.com]
    from: pgkeeper@example.com
    on: [failure]                  # add `success` for per-run success mail
    smtp: { host: smtp.example.com, port: 587,
            user_name: pgkeeper, password: <%= ENV["SMTP_PASSWORD"] %> }
  healthcheck:                     # dead-man's switch: pinged on success
    url: <%= ENV["PGKEEPER_HEALTHCHECK_URL"] %>

web:                               # optional dashboard; see §9
  auth:
    token: <%= ENV["PGKEEPER_WEB_TOKEN"] %>
```

Key details:

- **`databases[].format`** — `custom` (default; compressed, selective
  restore), `plain` (SQL text), `directory` (enables parallel `--jobs`).
- **`include_globals`** — also captures roles/tablespaces via
  `pg_dumpall --globals-only`. Without it, restoring to a *fresh* server
  fails on missing roles. Usually requires superuser; see SECURITY.md.
- **Passwords** — inline via ERB, or set `pgpass: true` per database to use
  `~/.pgpass`/`PGPASSFILE` instead. Credentials are passed to the tools as
  libpq environment variables, never on the command line.
- **Compression** is skipped automatically for `custom`/`directory` dumps
  (pg_dump already compressed them); `directory` outputs are zipped into a
  single artifact.
- **Schedules** accept raw cron (`"15 3 * * *"`), natural language
  (`every day at 03:15`, `every monday at 9am`), and shorthands (`hourly`,
  `daily at 03:15`, `weekly on sunday at 04:00`).
- **`timeouts:`** — wall-clock deadlines (seconds) for the external tools:
  `dump`, `restore`, `verify`, `query`. Generous defaults (6h/6h/1h/60s) so a
  real operation never trips them, but finite so a hung child can't block a run
  forever. Set any to `0` to disable that deadline.
- **`anomaly:`** — backup-size anomaly detection (on by default). A dump that
  shrank past `shrink_pct` (default 50%) vs the median of the last
  `sample_size` successful runs raises a warning in the CLI, log, and
  notification. Set `enabled: false` to turn it off, or `grow_pct` to also warn
  on unexpected growth.

The full annotated schema lives in
[`config/pgkeeper.example.yml`](../config/pgkeeper.example.yml).

## 6. Command reference

Global options on every command: `-c/--config PATH`, `--log-level
debug|info|warn|error`, `--log-format logfmt|json`, `--log-file PATH`.

Exit codes everywhere: **0** success · **1** partial (some databases or
destinations failed) · **2** total failure. Cron and CI can react to them.

| Command | What it does |
|---|---|
| `pgkeeper connect` (alias `onboard`) | Onboarding wizard: prompts for a database's connection details, live-tests them, takes a validated backup schedule, and writes/updates `pgkeeper.yml` (passwords as env-var references; an existing file's comments and ERB are preserved). |
| `pgkeeper doctor` | Checks tools on PATH, config validity, storage health, DB connectivity, and pg_dump-vs-server version drift. Run it after any config change. |
| `pgkeeper validate` | Loads the config and reports every schema problem at once. |
| `pgkeeper backup [--only NAME ...] [--destinations TOKEN ...]` | Runs the full pipeline for all (or selected) databases, fanning out to all (or selected) destinations. Lock-guarded — concurrent runs fail loudly instead of colliding. |
| `pgkeeper destinations` | Lists configured destinations and the tokens `--destinations` / the API accept. |
| `pgkeeper list [--only NAME ...]` | Lists backups on every destination: size, pipeline (`gzip+aes256gcm`), verified status. |
| `pgkeeper status [--database NAME --limit N]` | Run history: most recent backup per database, or recent runs for one. |
| `pgkeeper metrics [--output FILE]` | Prints Prometheus metrics from the run-history; `--output` writes an atomic node_exporter textfile (see §9). |
| `pgkeeper verify [SELECTOR] [--deep] [--only NAME ...]` | Verifies backups (see §8). SELECTOR: `latest` (default), `all`, or a timestamp label/prefix. |
| `pgkeeper prune [--apply] [--only NAME ...]` | Enforces retention. **Dry run by default** — prints what would be deleted; `--apply` deletes. |
| `pgkeeper restore [SELECTOR] [--database NAME] [--target NAME] [--force] [--jobs N]` | Restores a backup (see §8 and RESTORE.md). Overwriting a non-empty database requires `--force`. |
| `pgkeeper schedule [print\|install] [--systemd] [--output DIR] [--jitter N] [--bin PATH]` | Shows the resolved schedule, or emits crontab lines / systemd units (see §7). |
| `pgkeeper daemon [--jitter N]` | Runs the schedules in-process — for containers without cron/systemd. |
| `pgkeeper web [--bind ADDR] [--port N]` | Serves the dashboard (see §9). |
| `pgkeeper test-notification` | Sends a test summary through every configured notifier. |
| `pgkeeper version` | Prints the version. |

## 7. Scheduling

Set `schedule:` globally and/or per database — the `pgkeeper connect` wizard
takes one interactively (validating it and previewing the next few runs), or set
it by hand. A schedule accepts cron (`15 3 * * *`), natural language
(`every day at 03:15`), or a shorthand (`hourly`, `daily`). Then pick the runner
that fits the host:

**Cron** (simplest):

```sh
pgkeeper schedule install            # prints flock-guarded crontab lines
pgkeeper schedule install | crontab  # install them (replaces the crontab!)
```

**systemd** (preferred on modern Linux — journald logs, catch-up after
downtime via `Persistent=true`, stagger via `RandomizedDelaySec`):

```sh
sudo pgkeeper schedule install --systemd --jitter 300 --output /etc/systemd/system
sudo systemctl daemon-reload
sudo systemctl enable --now pgkeeper-all.timer      # name shown by the command
```

**Daemon** (containers, or anywhere without cron/systemd):

```sh
pgkeeper daemon --jitter 120        # runs in-process; jitter staggers multi-DB runs
```

**Schedule the upkeep jobs too, not just the backup.** A `maintenance:` block
automates verification and pruning the same way `schedule:` automates the
backup — so you don't have to remember to hand-wire a second cron line:

```yaml
maintenance:
  verify:
    schedule: weekly on sunday at 04:00
    deep: true             # Tier-3 scratch-restore
  prune:
    schedule: daily at 05:00
    apply: true            # actually delete (omit for dry-run)
```

`pgkeeper schedule install` then emits an independent, separately locked cron
line / systemd timer per job (`pgkeeper-verify-all.timer`,
`pgkeeper-prune-all.timer`), and `pgkeeper daemon` runs them in-process
alongside the backups. `pgkeeper schedule print` shows every job with its
action.

Whichever you choose, add the dead-man's switch (`notifications.healthcheck`)
— email alerts can't tell you about a scheduler that silently stopped
running, a missed ping can.

## 8. Verification and restore

**A backup you haven't restored is not a backup.** PgKeeper makes this a
first-class workflow with three tiers:

```sh
pgkeeper verify                 # Tier 1: re-checksum + Tier 2: prove the
                                #   archive is readable (pg_restore --list)
pgkeeper verify --deep          # Tier 3: restore into a throwaway scratch
                                #   database, sanity-check, drop it
pgkeeper verify all             # verify every stored backup, not just latest
```

Passing marks the backup `verified` in its manifest — visible in `list` and
the dashboard, and retention will never delete backups newer than the last
verified one. **Schedule `verify --deep` weekly** via the `maintenance.verify`
block (see §7) so it runs unattended like the backup itself.

Restore (full runbook in [RESTORE.md](RESTORE.md)):

```sh
pgkeeper restore latest --database app_production                # same-name restore
pgkeeper restore 2026-07-21 --database app_production \
                 --target app_staging --jobs 4                   # to another DB
```

- `SELECTOR` is `latest` or a timestamp label/prefix from `pgkeeper list`.
- Restores automatically reverse the pipeline (decrypt → decompress →
  `pg_restore`/`psql`), fetching from the local destination when available.
- A non-empty target aborts unless you pass `--force` — the one flag that
  should always make you pause.

## 9. Web dashboard

```yaml
web:
  auth:
    token: <%= ENV["PGKEEPER_WEB_TOKEN"] %>   # or username: + password:
    # ...or a revocable token per caller (name is logged with each action):
    # tokens:
    #   ci:          <%= ENV["PGKEEPER_TOKEN_CI"] %>
    #   backups-bot: <%= ENV["PGKEEPER_TOKEN_BOT"] %>
  # bind: 127.0.0.1     # default
  # port: 8321          # default
```

```sh
gem install rack puma          # optional deps; the Docker image has them
pgkeeper web
```

Open http://127.0.0.1:8321 — browsers log in via basic auth (**any username,
the token as the password**); scripts send `Authorization: Bearer <token>`.

Pages: **Overview** (per-database traffic lights, last verified age, next
run, size-trend sparklines, destination health), **Runs** (timeline + per-run
detail with stderr on failures), **Backups** (browse and download artifacts),
**Connections** (every endpoint PgKeeper talks to, probed live on page load —
databases, PITR clusters, and storage destinations, with server version and
round-trip latency; credentials never shown. Also tests a connection on
demand and adds a database to `pgkeeper.yml` from the browser: the connection
is probed first, the password lands as an `ENV` reference — export it and
restart pgkeeper to load the entry),
**Retention** (exactly what the next prune deletes), **Actions** (trigger
backup / verify / prune / test-notification / doctor — with a per-destination
picker on backup — each behind a confirmation, running through the same lock as
scheduled runs).

Trigger those actions remotely with the token-authenticated action API — start
a backup (optionally scoped to a database and destinations) and poll the job it
returns. Full reference in [REMOTE-API.md](REMOTE-API.md):

```sh
curl -X POST -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"destinations":["nas","gdrive"]}' localhost:8321/api/actions/backup
curl -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN" localhost:8321/api/jobs/1
```

JSON API and Prometheus metrics for monitors, same auth:

```sh
curl -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN" localhost:8321/api/status
curl -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN" "localhost:8321/api/runs?database=app_production&limit=10"
curl -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN" localhost:8321/api/destinations
curl -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN" localhost:8321/metrics   # Prometheus exposition
```

`/healthz` (liveness) and `/readyz` (readiness — workdir writable, history
readable) are **unauthenticated**, for container liveness/readiness probes and
load balancers:

```sh
curl localhost:8321/healthz    # -> 200 "ok"
curl localhost:8321/readyz     # -> 200 "ready" / 503 "not ready"
```

Without the dashboard, scrape backup state straight from the CLI — point the
node_exporter textfile collector at a scheduled `pgkeeper metrics --output`:

```sh
pgkeeper metrics --output /var/lib/node_exporter/textfile/pgkeeper.prom
```

The exposition includes `pgkeeper_last_success_timestamp_seconds`,
`pgkeeper_last_backup_size_bytes`, `pgkeeper_last_run_duration_seconds`, and
`pgkeeper_last_run_success` per database — enough to alert on "no successful
backup in 26 hours" or "last dump was 0 bytes".

The dashboard refuses to start without auth, binds loopback by default (put
a TLS reverse proxy in front for remote access), and deliberately has **no
restore button**. Details in [SECURITY.md](SECURITY.md).

## 10. Docker

The image bundles the CLI, daemon, dashboard, S3 SDK, and client tools:

```sh
docker build -t pgkeeper .

# Any one-off command:
docker run --rm -v ./pgkeeper.yml:/etc/pgkeeper/pgkeeper.yml:ro pgkeeper doctor

# Long-running: scheduler alone (default), or scheduler + dashboard:
docker run -d -v ./pgkeeper.yml:/etc/pgkeeper/pgkeeper.yml:ro \
  -v pgkeeper-backups:/var/backups/pgkeeper \
  -e PGKEEPER_APP_PASSWORD -e PGKEEPER_WEB_TOKEN \
  -p 127.0.0.1:8321:8321 pgkeeper daemon-with-web
```

For running next to your database in Compose, start from
[`docker-compose.example.yml`](../docker-compose.example.yml) — it wires the
service dependencies, volumes, and dashboard auth. Inside a container set
`web.bind: 0.0.0.0` (the published port stays loopback-only on the host).

## 11. Using PgKeeper as a Ruby library

The CLI is a thin layer; everything is drivable programmatically:

```ruby
require "pgkeeper"

config = PgKeeper::Config.load("pgkeeper.yml")
report = PgKeeper::Orchestrator.new(config).run          # or run(only: ["app"])

report.results.each do |r|
  puts "#{r.database}: #{r.status} (#{r.duration_seconds}s)"
end
exit report.exit_code
```

Also available: `PgKeeper::Pruner#prune(apply:)`, `PgKeeper::Verifier#verify`,
`PgKeeper::History` (run history), `PgKeeper::Catalog` (what's stored where).
Prefer running PgKeeper as its own scheduled process over triggering it from
inside your app, though — backups shouldn't share fate with the app process.

## 12. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `doctor`: `pg_dump: not found on PATH` | Install the PostgreSQL client tools (`postgresql-client`). |
| `doctor` warns `pg_dump X is older than server Y` | Upgrade the client — an older pg_dump against a newer server is a silent-corruption footgun. |
| `another PgKeeper run holds the lock` | A run is already in progress (or a dead run's process still holds the flock). Locks release when the process exits; find it with `fuser <workdir>/.pgkeeper.lock`. |
| `invalid configuration ... (N problem(s))` | Every problem is listed; fix them all at once. `pgkeeper validate` re-checks without touching anything. |
| Backup reports `partial` (exit 1) | The dump succeeded but at least one destination failed — check the per-destination lines in the output / run detail. The other destinations still have the backup. |
| `insufficient free space at <workdir>` | The preflight check refused to start a dump that wouldn't fit. Free space or move `workdir`. |
| S3: `aws-sdk-s3 is not installed` | `gem install aws-sdk-s3` (only needed for S3 targets). |
| Dashboard: `web dashboard auth is not configured` | Set `web.auth.token` (or username+password) — it will not start without credentials. |
| Dashboard: 401 with the right token | Browsers must send it as the basic-auth *password*; scripts as `Authorization: Bearer <token>`. |
| Restore refuses to run | The target database is non-empty; re-run with `--force` only once you're sure. |
| Notification failures in logs | Notifiers are deliberately non-fatal — the backup itself still succeeded; fix SMTP/webhook settings and use `pgkeeper test-notification`. |

Debugging aid: `--log-level debug --log-format json` on any command gives
structured logs of every step, including the exact external commands run.
