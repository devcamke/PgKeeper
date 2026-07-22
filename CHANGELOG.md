# Changelog

All notable changes to PgKeeper. Versions map to the milestones in
[PLAN.md](PLAN.md).

## Unreleased

### Added

- **Onboarding wizard (`pgkeeper connect`).** An interactive flow that connects
  a database and schedules its backups, then writes `pgkeeper.yml`. It collects
  the connection details, live-tests the credentials with a bounded `psql`
  round-trip (retry / save-anyway / abort on failure), takes a backup schedule
  validated through the same parser as the scheduler — with a preview of the
  next few fire times — and persists the result: a fresh, commented config on a
  new host, or an appended database entry on an existing one that leaves its
  comments and `<%= ENV[...] %>` interpolations untouched. Passwords are written
  as an env-var reference, never inlined, and the wizard prints the exact
  variable to export. On a fresh config the schedule is global; when appending,
  it rides on the new database so the others keep their own cadence. `onboard`
  is an alias. The prompt IO and connection prober are injectable, so the whole
  flow is unit-tested with no terminal and no live Postgres.

- **Named destinations & per-run destination selection.** Any `storage:` target
  can carry a friendly `name:` (e.g. `nas`, `gdrive`, `onedrive`); a run can be
  scoped to a subset of destinations instead of the full fan-out via
  `pgkeeper backup --destinations nas,gdrive` (names or types, comma-separated).
  The name becomes the destination's identity in run history, notifications, and
  the dashboard. New `pgkeeper destinations` lists the selectable tokens. The
  default is unchanged — omitting the flag still fans out to every destination.
- **Remote-trigger JSON API.** `pgkeeper web` now exposes token-authenticated
  `POST /api/actions/{backup,verify,prune}` endpoints that start the same
  lock-guarded background jobs as the dashboard and return a job id (HTTP 202) to
  poll at `GET /api/jobs/<id>` (`GET /api/jobs` lists recent jobs). `backup`
  accepts `database` and `destinations` (JSON or form-encoded). The Bearer token
  doubles as CSRF protection, so the API needs no form token/confirmation; a
  `web.auth.token` is required (basic-auth can't reach it). New
  `GET /api/destinations` returns the selectable tokens. The dashboard's Actions
  page gains a per-destination picker and copy-ready `curl` recipes. See
  [docs/REMOTE-API.md](docs/REMOTE-API.md).
- **Per-caller API tokens.** `web.auth.tokens` takes a map of name => secret, so
  each caller (CI, a bot, a teammate) gets its own token, revoked independently
  by dropping its entry and restarting. The authenticating caller's name is
  recorded on the request and logged with every action it triggers, giving a
  who-ran-what audit trail. The single `web.auth.token` and basic-auth pair
  still work and may coexist with a `tokens` map.
- **Subprocess timeouts (production safety).** Every `pg_dump`/`pg_dumpall`/
  `pg_restore`/`psql`/`df` call now runs under a configurable wall-clock deadline
  (new `PgKeeper::Subprocess`). On expiry the child's whole process group is
  signalled `TERM` then `KILL` and a `TimeoutError` is raised, so a hung child (a
  lock wait, a stalled network mount, a server that accepts the connection but
  never answers) can no longer block a run forever with no backup and no failure
  alert. Configurable via the new `timeouts:` block (`dump`/`restore`/`verify`/
  `query`, seconds; `0` disables); defaults are generous-but-finite.
- **Backup-size anomaly detection.** A fresh dump is compared against the median
  of recent successful runs from the SQLite history; one that shrank past the
  threshold (default 50%) raises a loud warning in the CLI output, structured
  log, and the run's notification (subject, text, HTML, JSON). This catches the
  silently-broken dump — a dropped table, a bad `exclude_tables`, a truncated
  database — that still exits 0. Configurable via the `anomaly:` block; growth
  warnings are opt-in. (PLAN.md Phase 11.)
- **Prometheus metrics.** `pgkeeper metrics` prints last run/success timestamps,
  last backup size, duration, and success per database; `--output FILE` writes an
  atomic node_exporter textfile. The dashboard also serves the same exposition at
  `/metrics` (behind its auth). (PLAN.md Phase 11.)
- **Dashboard health probes.** Unauthenticated `/healthz` (liveness) and
  `/readyz` (readiness — workdir writable, history readable) for container
  orchestrators and load balancers, served outside the auth layer so a probe
  needs no credential.
- **Release + supply-chain automation.** CI now runs `bundler-audit` and a PR
  dependency review, a weekly scheduled security run, and a Ruby 3.2/3.3/3.4
  compatibility matrix; a Dependabot config keeps dependencies and Actions
  current; and a tag-triggered release workflow builds the gem, verifies the tag
  matches `PgKeeper::VERSION`, and publishes a GitHub Release (with opt-in
  RubyGems trusted publishing). SimpleCov is available via `COVERAGE=1`.

### Changed

- **Deep-verify is now strict.** Tier-3 verification runs `pg_restore` with
  `--exit-on-error`, so a partially-failing custom-format restore fails
  verification instead of logging errors and exiting 0.
- **Refreshed the `pgkeeper web` dashboard UI.** A modern visual pass over the
  same read-mostly pages: a proper light/dark color system, a sticky top bar
  with a brand mark and tab-style nav, card-style tables with rounded corners
  and header fills, tinted status pills (replacing plain colored text), and
  accent-colored buttons and form controls. Purely presentational — the
  templates, routes, data, and auth are unchanged.

### Added

- **Dropbox storage backend** (`type: dropbox`, closing part of the Phase 4
  cloud-provider gap). No SDK required — it uses the Dropbox HTTP API v2
  directly. Large artifacts stream through an upload session, so dumps above
  Dropbox's 150 MB single-request ceiling upload with flat memory. Auth is a
  refresh-token triple (`refresh_token` + `app_key` + `app_secret`, exchanged
  for a short-lived access token per run) or a long-lived `access_token`.
  Health-checked by `pgkeeper doctor` and covered by the shared storage
  contract. See [docs/PROVIDERS.md](docs/PROVIDERS.md#dropbox).
- **Google Drive storage backend** (`type: google_drive`, closing more of the
  Phase 4 gap). No SDK required — it uses the Drive REST API v3 directly and
  signs its own service-account JWT (`credentials_json` inline or a
  `credentials_file` path). Each artifact is stored as a file named for its
  full path inside one shared folder (`folder_id`); large files stream through
  a resumable upload session. Health-checked by `pgkeeper doctor` and covered
  by the shared storage contract. See
  [docs/PROVIDERS.md](docs/PROVIDERS.md#google-drive).
- **SharePoint / OneDrive storage backend** (`type: sharepoint`, completing the
  Phase 4 cloud-provider set). No SDK required — it uses the Microsoft Graph
  API with an app-only (client-credentials) token from an Entra app
  registration (`tenant_id` + `client_id` + `client_secret`). Backups land in
  one drive (`drive_id`) under an optional `root` folder, addressed by path;
  large files stream through a Graph upload session. Health-checked by
  `pgkeeper doctor` and covered by the shared storage contract. See
  [docs/PROVIDERS.md](docs/PROVIDERS.md#sharepoint--onedrive).

### Changed

- **S3 uploads now use multipart** (via the SDK transfer manager) for files
  above 100 MiB, lifting the 5 GiB single-`PutObject` limit that previously
  made large dumps unstorable; smaller files still go in one request.
- **Disk preflight is size-aware**: it estimates the live database size
  (`pg_database_size`) and reserves a multiple of it for the staged pipeline,
  instead of only enforcing a fixed free-space floor. Falls back to the floor
  when the size can't be measured.

## 1.0.0 — 2026-07-22

Phases 9–10: the web dashboard, packaging, and the documentation set —
PgKeeper is feature-complete for v1.

### Added

- **Web dashboard** (`pgkeeper web`, Phase 9):
  - Overview with per-database traffic lights (last run, last verified age,
    next scheduled run), size-trend sparklines, and a per-destination status
    grid.
  - Run timeline and per-run detail pages (duration, per-destination status,
    error output on failures), backed by the same SQLite run-history the CLI
    writes.
  - Retention view: the policy plus exactly what the next prune would delete.
  - Backups browser with artifact/manifest downloads, allowlisted against the
    destination catalog.
  - Management actions — backup, verify (deep optional), prune (dry-run or
    apply), test notification, doctor — each behind a CSRF token and an
    explicit confirmation, running as background jobs through the same lock
    as scheduled runs. Restores stay CLI-only by design.
  - JSON API (`/api/status`, `/api/runs`) for external monitors.
  - Security: mandatory auth (bearer token or basic auth, constant-time
    comparison), `127.0.0.1` bind by default, CSRF on every POST.
  - New `web:` config block (`bind`, `port`, `auth.token` /
    `auth.username`+`auth.password`).
  - rack/puma are optional dependencies — headless installs don't pay for
    the dashboard.
- **Packaging & docs** (Phase 10):
  - `Dockerfile` (ruby-slim + postgresql-client) with an entrypoint that runs
    the daemon, the dashboard, or both (`daemon-with-web`), and
    `docker-compose.example.yml` wiring PgKeeper next to a database with the
    dashboard auth pre-configured.
  - `docs/SECURITY.md`: least-privilege `backup_user` role, secret handling,
    encryption guidance, dashboard security model.
  - `docs/PROVIDERS.md`: per-provider storage setup (AWS S3, MinIO,
    Backblaze B2, Cloudflare R2, Spaces).
- `History#runs_for(run_id)` to read all rows of one run.

### Fixed

- SQLite lookups now normalize string parameters to UTF-8; binary-encoded
  strings (e.g. sliced from a Rack `PATH_INFO`) previously bound as BLOBs and
  never matched TEXT columns.

### Known gaps (documented, planned post-v1 — PLAN.md Phase 11)

- Logical dumps only: no WAL archiving / point-in-time recovery. Everything
  since the last dump is lost on restore — schedule accordingly.
- Cloud storage beyond the S3 family (Google Drive, Dropbox, SharePoint) is
  not yet implemented.

## 0.8.0

Phase 8 — scheduling & automation: `schedule:` expressions (cron, natural
language, shorthands), `pgkeeper schedule install` (flock-guarded crontab
lines or systemd service+timer units with stagger and catch-up), and
`pgkeeper daemon` for containers.

## 0.7.0

Phase 7 — notifications, reporting & run-history: email (SMTP+TLS, HTML+text),
generic/Slack webhook, dead-man's-switch pings, SQLite run-history store and
`pgkeeper status`. Notifier failures never affect the backup.

## 0.3.0

Phases 5–6 — retention & verified restore: `keep_last`/GFS pruning per
destination with safety rails, `pgkeeper verify` tiers 1–3 (checksum,
structural, deep scratch-database restore), `pgkeeper restore` with `--force`
guard, `docs/RESTORE.md` runbook.

## 0.2.0

Phases 3–4 — compression, encryption, storage fan-out: gzip/zip/zstd,
AES-256-GCM / GPG encryption at rest, storage adapter contract with
retry+backoff and independent per-destination status, local + S3-compatible
backends.

## 0.1.0

Phases 0–2 — foundation: gem/CLI skeleton, strict YAML+ERB config, doctor,
structured logging, pg_dump/pg_dumpall engine with locking, staging + atomic
finalize, SHA-256 manifests, meaningful exit codes.
