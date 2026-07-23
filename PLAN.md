# PgKeeper — PostgreSQL Backup Solution: Multi-Phase Plan

A full-fledged, automated PostgreSQL backup tool written in **Ruby**, tested with **Minitest**.
It dumps databases on a schedule, compresses/zips the output, stores it locally and/or pushes
it to cloud storage (Google Drive, Dropbox, SharePoint/OneDrive, S3-compatible), enforces
retention policies, verifies backups, reports status via email, and ships an optional web
dashboard for monitoring and management.

---

## Guiding Principles

- **A backup you haven't restored is not a backup.** Verification and restore are first-class
  features, not afterthoughts.
- **Fail loudly.** Every failure path must produce a notification and a non-zero exit code.
- **Pluggable everything.** Storage backends, notifiers, and compressors sit behind small
  interfaces so new providers are additive, not invasive.
- **No secrets in config files committed to git.** Environment variables / secret files only.
- **TDD with Minitest** throughout; external services mocked with WebMock/VCR.

---

## Architecture Overview

```
                ┌────────────────────────────────────────────────┐
                │                  PgKeeper CLI                  │
                │      (thor: backup / restore / verify /        │
                │    list / prune / doctor / schedule / web)     │
                └───────────────────┬────────────────────────────┘
                                    │
                        ┌───────────▼───────────┐
                        │      Orchestrator      │  ← run lifecycle, locking,
                        │  (per-database runs)   │    manifest, error handling
                        └───┬───────┬───────┬────┘
                            │       │       │
              ┌─────────────▼─┐ ┌───▼────┐ ┌▼──────────────┐
              │  Dump Engine  │ │Compress│ │  Encryption   │
              │ (pg_dump /    │ │ (gzip/ │ │  (optional,   │
              │  pg_dumpall)  │ │ zip/   │ │   GPG/AES)    │
              └───────────────┘ │ zstd)  │ └───────────────┘
                                └───┬────┘
                     ┌──────────────┼─────────────────────────┐
              ┌──────▼─────┐ ┌──────▼──────┐          ┌───────▼──────┐
              │  Storage   │ │  Notifiers  │          │  Retention   │
              │  Adapters  │ │ (Email SMTP,│          │  (GFS prune  │
              │ Local | GD │ │  webhooks)  │          │  per target) │
              │ Dropbox |  │ └─────────────┘          └──────────────┘
              │ SharePoint │
              │ | S3       │
              └────────────┘
```

### Proposed directory layout

```
pgkeeper/
├── bin/pgkeeper                  # executable entrypoint
├── lib/
│   ├── pgkeeper.rb
│   └── pgkeeper/
│       ├── version.rb
│       ├── cli.rb                # thor-based CLI
│       ├── config.rb             # YAML + ENV config loading & validation
│       ├── orchestrator.rb       # run lifecycle
│       ├── lock.rb               # prevent concurrent runs
│       ├── manifest.rb           # per-backup metadata (JSON sidecar)
│       ├── dump/
│       │   ├── pg_dump.rb        # single-db dump (custom/plain format)
│       │   └── pg_dumpall.rb     # globals/roles/cluster dump
│       ├── compress/
│       │   ├── gzip.rb
│       │   ├── zip.rb
│       │   └── zstd.rb
│       ├── crypto/
│       │   └── encryptor.rb      # optional GPG / OpenSSL AES-256
│       ├── storage/
│       │   ├── base.rb           # adapter interface
│       │   ├── local.rb
│       │   ├── google_drive.rb
│       │   ├── dropbox.rb
│       │   ├── sharepoint.rb     # Microsoft Graph API
│       │   └── s3.rb             # AWS S3 / MinIO / B2 (stretch)
│       ├── retention.rb          # keep-last-N + GFS policies
│       ├── verify.rb             # checksum + pg_restore --list / restore test
│       ├── notify/
│       │   ├── base.rb
│       │   ├── email.rb          # mail gem, SMTP
│       │   └── webhook.rb        # healthchecks.io / Slack (stretch)
│       ├── history.rb            # SQLite run-history store
│       ├── web/
│       │   ├── app.rb            # Sinatra dashboard (optional `pgkeeper web`)
│       │   ├── auth.rb           # basic-auth / token middleware
│       │   └── views/            # ERB templates
│       └── logging.rb            # structured logs
├── test/                         # Minitest
│   ├── test_helper.rb
│   ├── unit/...
│   └── integration/...
├── config/pgkeeper.example.yml
├── Gemfile / pgkeeper.gemspec
├── Rakefile                      # rake test, rake lint
├── Dockerfile
└── .github/workflows/ci.yml
```

### Key gem choices

| Concern        | Choice                                   | Notes |
|----------------|------------------------------------------|-------|
| CLI            | `thor`                                   | subcommands, help text |
| DB dump        | shell out to `pg_dump`/`pg_restore` via `Open3` | never reimplement dumping |
| Compression    | `zlib` (stdlib), `rubyzip`, `zstd-ruby`  | zip for user-friendliness, zstd for size/speed |
| Google Drive   | `google-apis-drive_v3` + `googleauth`    | service account or OAuth refresh token |
| Dropbox        | Faraday against Dropbox API v2           | official SDK is unmaintained; API is simple |
| SharePoint     | Faraday against Microsoft Graph          | OAuth2 client-credentials flow |
| S3 (stretch)   | `aws-sdk-s3`                             | also covers MinIO/Backblaze |
| Email          | `mail`                                   | plain SMTP, TLS |
| Run history    | `sqlite3`                                | single-file store, feeds `status` + dashboard |
| Dashboard      | `sinatra` + `puma`, ERB views            | optional `pgkeeper web` subcommand |
| Testing        | `minitest`, `webmock`, `vcr`, `mocha`, `rack-test` | plus dockerized Postgres for integration |
| Lint           | `rubocop` + `rubocop-minitest`           | |

---

## Phase 0 — Project Bootstrap & Skeleton

**Goal:** a runnable, testable, CI-checked empty shell.

- Initialize gem structure (`pgkeeper.gemspec`, `Gemfile`, `Rakefile`, `bin/pgkeeper`).
- Set up Minitest (`rake test`), RuboCop, and a GitHub Actions CI matrix (Ruby 3.2/3.3/3.4).
- `pgkeeper version` and `pgkeeper doctor` commands (doctor checks: `pg_dump` on PATH,
  version compatibility vs server, config readable, disk space, connectivity).
- Structured logging (JSON or logfmt option) with levels; log to stdout + optional file.

**Exit criteria:** `bundle exec rake test` green in CI; `pgkeeper doctor` reports environment status.

---

## Phase 1 — Configuration & Secrets

**Goal:** one declarative config file drives everything.

- YAML config (`pgkeeper.yml`) with ERB interpolation for `ENV` vars:

```yaml
databases:
  - name: app_production
    host: db.internal
    port: 5432
    username: backup_user
    password: <%= ENV["PGKEEPER_APP_PASSWORD"] %>
    format: custom            # custom | plain | directory
    include_globals: true     # also run pg_dumpall --globals-only
compression: zip              # zip | gzip | zstd | none (custom format is pre-compressed)
encryption:
  enabled: false
storage:
  - type: local
    path: /var/backups/pgkeeper
  - type: google_drive
    folder_id: <%= ENV["GDRIVE_FOLDER_ID"] %>
retention:
  keep_daily: 7
  keep_weekly: 4
  keep_monthly: 6
notifications:
  email:
    smtp: { host: smtp.example.com, port: 587, user_name: ..., password: <%= ENV["SMTP_PASSWORD"] %> }
    to: [ops@example.com]
    on: [success, failure]    # configurable; failure always recommended
```

- Strict schema validation with actionable error messages (unknown keys, missing required
  fields, bad enum values) — fail fast before touching the database.
- Support `PGPASSFILE`/`.pgpass` and libpq env vars as alternatives to inline passwords.
- Multiple databases per run; per-database overrides of global settings.

**Tests:** config parsing, ENV interpolation, validation failures, defaults.

**Exit criteria:** `pgkeeper doctor` validates a real config end-to-end.

---

## Phase 2 — Core Backup Engine (pg_dump)

**Goal:** reliable local dumps with metadata.

- `Dump::PgDump` shells out to `pg_dump` via `Open3.capture3`, streaming stderr to logs.
  - Formats: `custom` (default — compressed, supports parallel & selective restore),
    `plain` (SQL), `directory` (enables `--jobs` parallel dump for large DBs).
  - Flags: `--no-password` (creds via env/pgpass), optional `--schema`/`--exclude-table`.
- `Dump::PgDumpall --globals-only` for roles/tablespaces (frequently forgotten — without it
  a restore to a fresh server fails on missing roles).
- Run lifecycle in `Orchestrator`:
  1. acquire lock (flock-based — prevents overlapping cron runs),
  2. dump to a temp workdir with atomic rename on success (no half-written backups),
  3. compute SHA-256 checksum,
  4. write a **manifest** sidecar JSON: db name, server version, pg_dump version, start/end
     time, duration, size, checksum, format, compression, pgkeeper version, hostname.
- Timestamped naming convention: `app_production-2026-07-20T031500Z.dump`.
- Clear exit codes: `0` success, `1` partial (some DBs failed), `2` total failure.
- Timeout + disk-space preflight check before dumping.

**Tests:** unit tests with mocked `Open3`; integration tests against a Dockerized Postgres
(seed schema → dump → assert artifact + manifest correctness).

**Exit criteria:** `pgkeeper backup --only app_production` produces dump + checksum + manifest locally.

---

## Phase 3 — Compression, Archiving & Optional Encryption

**Goal:** small, portable, optionally encrypted artifacts.

- Compressor interface with `gzip` (stdlib), `zip` (rubyzip — bundles dump + manifest into
  one shareable archive), and `zstd` (best ratio/speed for large dumps).
- Smart default: skip double-compression when `pg_dump --format=custom` already compresses;
  allow `--compress=0` on pg_dump when an external compressor is chosen.
- Streaming compression (pipe) where possible to avoid 2× disk usage on large databases.
- **Optional encryption at rest** (worth having before anything goes to third-party clouds):
  - OpenSSL AES-256-GCM with a passphrase/keyfile, or GPG recipient-based encryption.
  - Manifest records encryption type; restore path decrypts transparently.

**Tests:** round-trip compress→decompress equality; zip archive contains dump + manifest;
encryption round-trip; corrupted-archive detection.

**Exit criteria:** configurable compression/encryption produces verified round-trippable artifacts.

---

## Phase 4 — Storage Abstraction + Local & Cloud Backends

**Goal:** the same backup fans out to N destinations.

- `Storage::Base` interface: `upload(file, remote_path)`, `list(prefix)`, `delete(remote_path)`,
  `download(remote_path, local)`, `healthcheck`.
- **Local**: copy/move to target dir, correct permissions (0600), fsync, free-space check.
- **Google Drive**: `google-apis-drive_v3`; service-account or OAuth refresh-token auth;
  resumable/chunked uploads for large files; folder-per-database layout.
- **Dropbox**: API v2 via Faraday; `/upload` for <150 MB, upload sessions (chunked) above.
- **SharePoint/OneDrive**: Microsoft Graph, OAuth2 client-credentials; upload sessions for
  large files; site + document-library configurable.
- **S3-compatible** (stretch but cheap to add): `aws-sdk-s3`, works for AWS/MinIO/Backblaze/R2.
- Cross-cutting behavior in the base class:
  - retry with exponential backoff + jitter on transient errors (429/5xx/network),
  - upload verification (size and, where the API offers it, checksum comparison),
  - per-destination success/failure tracked independently — one cloud being down must not
    fail the local copy, and the run report shows per-destination status.

**Tests:** adapter contract test suite run against every backend (mocked with WebMock/VCR);
retry/backoff behavior; chunked upload paths; partial-failure reporting.

**Exit criteria:** one `pgkeeper backup` run lands the artifact on local disk + at least one
cloud provider, with per-destination status in the manifest.

---

## Phase 5 — Retention & Pruning

**Goal:** storage doesn't grow forever; old backups die predictably.

- Policies: simple `keep_last: N` and **GFS (grandfather-father-son)**: `keep_daily`,
  `keep_weekly`, `keep_monthly`, `keep_yearly`.
- Retention enforced **per destination** (e.g., 7 daily local, 30 daily in Drive).
- `pgkeeper prune` command with `--dry-run` (prints what would be deleted) — dry-run is the
  default the first time a new policy takes effect.
- Safety rails: never delete the most recent successful backup; refuse to prune to zero;
  never delete artifacts newer than the last verified backup.
- `pgkeeper list` shows backups across all destinations with age, size, verified status.

**Tests:** GFS edge cases (DST transitions, month boundaries, gaps from failed runs),
dry-run produces no deletions, safety rails.

**Exit criteria:** scheduled runs keep every destination trimmed to policy.

---

## Phase 6 — Verification & Restore (the phase everyone skips)

**Goal:** provable, one-command recoverability.

- **Tier 1 — integrity:** SHA-256 checksum re-validation after upload/download.
- **Tier 2 — structural:** `pg_restore --list` against the artifact (proves the dump is a
  readable, complete archive).
- **Tier 3 — full restore test:** `pgkeeper verify --deep` restores into a scratch database
  (local or Dockerized Postgres), runs sanity queries (table counts, optional user-defined
  smoke queries from config), then drops it. Schedule weekly.
- `pgkeeper restore` command: pick backup by name/date/`latest`, fetch from any destination,
  decrypt/decompress, `pg_restore` with `--jobs`, target-db safety confirmation
  (`--force` required to overwrite an existing non-empty database).
- Restore runbook auto-generated in the repo (`docs/RESTORE.md`) — humans at 3 a.m. need it.

**Tests:** integration round-trip backup→upload→download→restore→data equality assertions;
tampered-file detection; refuse-to-overwrite behavior.

**Exit criteria:** `pgkeeper verify --deep latest` passes in CI against a seeded database.

---

## Phase 7 — Notifications & Reporting

**Goal:** humans know the state of their backups without checking.

- **Email (mail gem, SMTP + TLS):**
  - success summary: per-DB and per-destination table (size, duration, checksum, retention
    actions taken), HTML + plain-text parts;
  - failure alert: failed step, stderr excerpt, log tail, next-steps hint;
  - configurable triggers: `on: [success, failure]` — failure notifications on by default
    and *not* silently disableable together with success (silence-is-failure problem);
  - digest mode option (one daily email instead of per-run).
- **Dead-man's switch:** optional ping to healthchecks.io / Uptime Kuma on success — catches
  the worst failure mode: cron silently not running at all. An email system can't tell you
  about a run that never happened; a missed ping can.
- Webhook notifier (generic JSON POST → Slack/Teams/Discord) as a thin second backend.
- Run summary also persisted to a local SQLite run-history store (`history.rb`) — powers
  `pgkeeper status` now and the web dashboard in Phase 9.

**Tests:** mail rendering (both parts), trigger matrix, SMTP failure doesn't crash the
backup itself (notification errors are logged, never fatal to the run).

**Exit criteria:** real SMTP delivery of success + failure mails; healthcheck ping fires.

---

## Phase 8 — Scheduling & Automation

**Goal:** unattended operation on any host.

- `pgkeeper schedule install` generates either:
  - a **cron** entry (via crontab, with flock guard), or
  - **systemd** service + timer units (preferred on modern Linux: journald logs,
    `Persistent=true` catch-up after downtime, resource limits).
- Config: per-database schedule expressions (`daily at 03:15`, raw cron syntax accepted).
- Long-running daemon mode (`pgkeeper daemon`, rufus-scheduler) for container deployments
  where cron isn't available.
- Jitter/stagger for multi-DB setups so dumps don't all hit at once.
- Documentation for Windows Task Scheduler for that audience.

**Tests:** schedule expression parsing, generated unit files/cron lines (golden-file tests),
daemon tick behavior with a fake clock.

**Exit criteria:** a fresh VM goes from `gem install` to nightly automated verified backups
with one documented command sequence.

---

## Phase 9 — Web Dashboard (Monitoring & Management)

**Goal:** a browser view of backup health, plus safe management actions — without making
the core pipeline depend on an always-running web process.

- Optional `pgkeeper web` subcommand (Sinatra + Puma, ERB views); headless installs never
  pay for it. Reads the same SQLite run-history store and manifests the CLI uses — no
  separate data path to drift out of sync.
- **Monitoring (read-only, built first):**
  - overview page: per-database traffic lights (last success age, last verified age,
    next scheduled run),
  - backup timeline and size-trend sparkline per database (surfaces the "dump suddenly
    60% smaller" anomaly visually),
  - per-destination status grid (uploaded / failed / pruned counts, free-space where known),
  - run detail page: duration, checksum, log tail and stderr excerpt on failures,
  - retention view: what exists where, what the next prune will delete.
- **Management actions (second, each behind a confirmation step):**
  - trigger backup / verify / prune now (runs enqueue through the same lock as cron —
    never a second concurrent pipeline),
  - browse and download artifacts from any destination,
  - send a test notification; re-run `doctor` and show results,
  - enable/disable a database's schedule.
  - **Not included:** restore-from-browser. Restores stay CLI-only (`docs/RESTORE.md`) —
    too destructive for a web click.
- **Security from day one:** auth required before first release of the page (basic-auth or
  token, constant-time comparison), binds to `127.0.0.1` by default (reverse-proxy for
  remote access), CSRF protection on all POST actions, no credentials ever rendered.
- JSON API endpoints (`/api/status`, `/api/runs`) so external monitors can scrape the same
  data the dashboard shows.

**Tests:** `rack-test` request specs for every page and action, auth-required-everywhere
matrix, CSRF rejection, management actions respect the run lock, JSON API contract tests.

**Exit criteria:** `pgkeeper web` shows live health for a real multi-DB config; a triggered
backup from the browser completes and appears in the timeline; every route 401s without
credentials.

---

## Phase 10 — Packaging, Docker & Docs

**Goal:** easy adoption and repeatable deployment.

- Publish gem (`gem install pgkeeper`).
- **Dockerfile** (ruby-slim + postgresql-client matching major versions) and a
  `docker-compose.example.yml` (pgkeeper + its cron/daemon alongside a database).
- Documentation set:
  - README quickstart (5-minute local backup),
  - per-provider auth setup guides (Google service account, Azure app registration for
    SharePoint, Dropbox app token) — these are the #1 support burden, write them carefully,
  - `docs/RESTORE.md` runbook, `docs/SECURITY.md` (least-privilege `backup_user` role,
    secret handling), CHANGELOG, upgrade notes.
- `pgkeeper doctor` extended to validate each configured provider's credentials with a
  harmless API call.
- Docker image runs the daemon + dashboard together behind one entrypoint;
  `docker-compose.example.yml` exposes the dashboard port with auth pre-wired.

**Exit criteria:** a newcomer reaches a working scheduled cloud backup using only the docs.

---

## Phase 11 — Hardening & Nice-to-Haves (post-v1 backlog)

- **WAL archiving / PITR**: logical dumps lose everything since the last dump. Documented as
  a boundary in v1 (`docs/RPO-RTO.md`); **now a dedicated phase — see Phase 12** — rather
  than a loose backlog line.
- Very-large-DB support: directory format + `--jobs`, per-table parallel strategies,
  bandwidth throttling for uploads.
- Metrics endpoint / Prometheus textfile exporter (last success timestamp, duration, size).
- Backup size anomaly detection (today's dump 60% smaller than yesterday's → warn loudly —
  classic sign of a silently broken dump).
- Multi-server orchestration (one PgKeeper host backing up many clusters).
- Sensitive-data filtering (exclude tables / anonymization hooks) for dev-copy exports.
- Dashboard extras: multi-user accounts/roles, restore-from-browser (if ever, behind heavy
  guards), historical charts beyond the v1 sparklines.

---

## Phase 12 — Point-in-Time Recovery (PITR) via WAL Archiving

> **Detailed design:** [docs/PITR-DESIGN.md](docs/PITR-DESIGN.md) — config surface,
> module layout, coupled-retention algorithm, restore orchestration, failure modes,
> and a staged (per-PR) rollout. Read that before implementing.

**Goal:** shrink the recovery-point boundary from "your last logical dump" to "any moment
you choose" — bounding data loss by the WAL-shipping interval (seconds-to-minutes) instead
of the backup interval (hours-to-days). This is the one recovery capability logical dumps
structurally cannot provide, and the most-requested step beyond v1.

**Why it's a phase, not a flag:** PITR is a different backup *model*, not a bigger dump. It
pairs a periodic **physical base backup** (`pg_basebackup`) with a **continuous stream of
WAL segments**; recovery replays WAL from a base up to a chosen target (time, LSN, or named
restore point). It coexists with — does not replace — the logical-dump pipeline: logical
dumps stay the portable, cross-version, selective-restore path; PITR adds low-RPO recovery
for a specific cluster. Both remain first-class.

- **WAL archiving (`WAL::Archiver`)** — ship completed WAL segments to the same storage
  destinations the dump pipeline already fans out to. Two supported modes:
  - `pg_receivewal` as a managed streaming child (a long-lived process the daemon
    supervises, giving near-real-time, gap-free capture with its own replication slot), and
  - a pull/archive_command bridge for hosts where PgKeeper can only see an archive directory.
  - Reuse the Phase 4 storage adapters (upload/list/delete/healthcheck), so WAL lands in
    Local / S3 / B2 / R2 / Spaces exactly like dumps, with the same retry/backoff and
    per-destination independence.
- **Base backups (`Backup::Base` via `pg_basebackup`)** — periodic physical base backups
  (their own `schedule:`), compressed and encrypted through the existing Phase 3 pipeline,
  manifested (base LSN, timeline, server version) like every other artifact.
- **Coupled retention** — a base backup and the WAL needed to recover *from* it are one unit.
  Extend Phase 5 retention so pruning a base **never** strands WAL that a surviving base
  still needs, and never deletes WAL required to reach the recovery horizon. New safety rail:
  refuse to prune below the configured **recovery window** (e.g. "keep 7 days of PITR").
- **`pgkeeper restore --to <target>`** — extend the restore command with PITR targets:
  `--to-time`, `--to-lsn`, `--to-name` (named restore point), or `latest`. Fetch the right
  base + WAL range, stage `recovery.signal` + `restore_command`, and drive Postgres recovery,
  with the same `--force`/target-safety guards as logical restore. Runbook in
  `docs/RESTORE.md` gets a PITR section (the 3 a.m. reader needs the exact `--to-time` recipe).
- **`pgkeeper verify --pitr`** — deep verification for PITR: restore a base into a scratch
  cluster, replay a bounded WAL range, and assert it reaches a consistent recovery point.
  A base whose WAL chain has a gap **fails** — same philosophy as Tier-3 dump verification.
- **Observability** — WAL-archiving lag (age of the newest archived segment) and the current
  recovery window surface in `status`, the dashboard overview, `metrics`/Prometheus, and the
  dead-man's switch, so "WAL shipping silently stopped" is loud, not discovered at restore.
- **`doctor` / config** — validate PITR prerequisites up front: `wal_level >= replica`,
  a reachable replication slot / sufficient `max_wal_senders`, `pg_basebackup` present and
  version-matched, and archive-destination writability. A `pitr:` config block (per cluster)
  carries mode, base-backup schedule, recovery window, and destination selection.

**Tests:** Dockerized-Postgres integration — seed → base backup → generate WAL by writing
rows with recorded timestamps/LSNs → restore `--to-time`/`--to-lsn` → assert the cluster
contains exactly the rows written before the target and none after; gap-in-WAL detection
fails verify; retention never strands required WAL (property test over base/WAL timelines);
`pg_receivewal` supervision restarts cleanly and resumes without a gap.

**Exit criteria:** from a base backup plus archived WAL, `pgkeeper restore --to-time <ts>`
recovers a cluster to that instant in CI, and retention/verify keep the WAL chain provably
intact.

---

## Things Easily Forgotten (baked into the phases above)

| Gap | Where handled |
|---|---|
| Roles/globals not in `pg_dump` → restore fails on fresh server | Phase 2 (`pg_dumpall --globals-only`) |
| Overlapping runs corrupting state | Phase 2 (locking) |
| Half-written backup files | Phase 2 (temp + atomic rename) |
| Restore never actually tested | Phase 6 (tiered verification, weekly deep verify) |
| Unencrypted dumps on third-party clouds | Phase 3 (encryption before Phase 4 uploads) |
| Cron silently dead → no emails, no backups, nobody notices | Phase 7 (dead-man's switch) |
| Notification failure killing the backup | Phase 7 (non-fatal notifiers) |
| One cloud outage failing the whole run | Phase 4 (independent per-destination status) |
| Disk filling up | Phase 2 (preflight) + Phase 5 (retention) |
| Deleting your only good backup | Phase 5 (safety rails) |
| `pg_dump`/server version mismatch | Phase 0/10 (`doctor`) |
| Secrets in config files | Phase 1 (ENV/ERB, pgpass support) |
| Unauthenticated dashboard exposing backup data | Phase 9 (auth + localhost bind + CSRF from day one) |
| Restore triggered by a stray web click | Phase 9 (restores stay CLI-only) |
| PITR expectations vs logical dumps | Phase 6/10 (documented boundary) → Phase 12 (WAL archiving + PITR restore) |
| Pruning a base backup stranding the WAL it needs | Phase 12 (coupled base+WAL retention, recovery-window rail) |
| WAL shipping silently stopping | Phase 12 (WAL-lag in status/dashboard/metrics/dead-man's switch) |

---

## Testing Strategy (Minitest, applied every phase)

- **Unit**: pure-Ruby logic (config, retention math, naming, manifest) — fast, no I/O.
- **Contract**: one shared Minitest module exercised against every storage adapter and every
  notifier, so all backends provably behave identically at the interface.
- **Integration**: Dockerized Postgres (via `docker compose` in CI) for real dump/restore
  round-trips; WebMock/VCR cassettes for cloud APIs.
- **End-to-end smoke** in CI: seed DB → backup → zip → "upload" to local-fs fake cloud →
  prune → deep verify → assert email rendered.
- Style: `rake test` runs everything; `rake test:unit` for the fast loop; RuboCop +
  `rubocop-minitest` enforced in CI.

## Suggested Milestones

| Milestone | Phases | Outcome |
|---|---|---|
| **v0.1** | 0–2 | Local scheduled-able dumps with manifests |
| **v0.2** | 3–4 | Compressed/zipped, optionally encrypted, multi-destination cloud uploads |
| **v0.3** | 5–6 | Retention + verified restores |
| **v1.0** | 7–10 | Email reporting, scheduling installer, web dashboard, Docker, docs — production-ready |
| **v1.x** | 11 | Metrics, anomaly detection, very-large-DB support, dashboard extras |
| **v2.0** | 12 | Point-in-time recovery: WAL archiving + base backups + `restore --to-time` |
