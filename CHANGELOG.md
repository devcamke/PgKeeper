# Changelog

All notable changes to PgKeeper are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Planned
- Web dashboard (`pgkeeper web`) — read-only backup-health view + JSON API (Phase 9).
- Published gem on RubyGems and additional cloud storage backends (Google Drive,
  Dropbox, SharePoint/OneDrive).

## [0.9.0] — 2026-07-22

Packaging, Docker & documentation. Everything built so far is now installable
and deployable.

### Added
- **Dockerfile** (Ruby 4 + `postgresql-client`, non-root) and
  `docker-compose.example.yml` running the scheduler daemon beside Postgres.
- Documentation: `docs/SECURITY.md` (least-privilege backup role, secret
  handling), `docs/STORAGE.md` (S3-compatible provider setup), this changelog,
  and a Docker quickstart in the README.
- Gem metadata (source, changelog, issues) and docs bundled into the gem.

## [0.8.0] — Scheduling & automation (Phase 8)

### Added
- `schedule:` config (cron, natural language, and shorthands) globally and
  per-database.
- `pgkeeper schedule install` — flock-guarded crontab lines or systemd
  service+timer units; `pgkeeper schedule print` shows the resolved plan.
- `pgkeeper daemon` — in-process scheduler for containers, with jitter.

## [0.7.0] — Notifications & reporting (Phase 7)

### Added
- SQLite run-history and `pgkeeper status`.
- Email (SMTP+TLS), webhook (generic/Slack), and dead-man's-switch notifiers;
  `pgkeeper test-notification`. Notifier failures never affect the backup.

## [0.3.0] — Retention & verified restore (Phases 5–6)

### Added
- Retention policies (`keep_last` + GFS) and `pgkeeper prune` (dry-run default).
- Tiered `pgkeeper verify` (checksum → structural → `--deep` scratch restore)
  and `pgkeeper restore` (guarded overwrite); `docs/RESTORE.md`.

## [0.2.0] — Compression, encryption & storage fan-out (Phases 3–4)

### Added
- gzip/zip/zstd compression and AES-256-GCM / GPG encryption at rest.
- Storage abstraction with local + S3-compatible backends, retry/backoff, and
  independent per-destination status.

## [0.1.0] — Core dump engine (Phases 0–2)

### Added
- Gem skeleton, `thor` CLI, structured logging, `doctor`, CI.
- YAML config with ERB/ENV interpolation and strict validation.
- `pg_dump`/`pg_dumpall` engine with locking, atomic writes, SHA-256 manifests.

[Unreleased]: https://github.com/devcamke/pgkeeper/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/devcamke/pgkeeper/releases/tag/v0.9.0
