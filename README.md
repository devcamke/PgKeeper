# PgKeeper

A full-fledged, automated PostgreSQL backup solution in Ruby.

PgKeeper dumps your databases on a schedule, compresses and optionally encrypts the
artifacts, stores them locally and/or in the cloud (Google Drive, Dropbox,
SharePoint/OneDrive, S3-compatible), enforces retention policies, verifies that backups
are actually restorable, and reports status via email.

**Status:** planning. See [PLAN.md](PLAN.md) for the full multi-phase build plan,
architecture, and milestones.

## Stack

- Ruby (gem-packaged CLI, `thor`)
- `pg_dump` / `pg_restore` under the hood
- Minitest for testing (unit, adapter contract, and Dockerized-Postgres integration tests)
