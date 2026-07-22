# Changelog

All notable changes to PgKeeper. Versions map to the milestones in
[PLAN.md](PLAN.md).

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
