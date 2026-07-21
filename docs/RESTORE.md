# PgKeeper Restore Runbook

The instructions you need at 3 a.m. Restores are **CLI-only** and destructive —
PgKeeper deliberately has no "restore from the web dashboard" button.

## 0. Before you start

- Know **which database** and **which backup** you want. `pgkeeper list` shows
  every backup across every destination, newest first, with its verification
  status.
- Have the config that produced the backup (or an equivalent one). Restoring an
  **encrypted** backup requires the same `encryption:` settings and the
  passphrase/keyfile used to create it — without them the artifact cannot be
  decrypted.
- Make sure `pg_restore` / `psql` are on PATH and the target server is
  reachable: `pgkeeper doctor`.

## 1. Find the backup

```sh
pgkeeper list -c pgkeeper.yml
```

```
local:/var/backups/pgkeeper/backups
  2026-07-21T031500Z     app_production      412.5MB  gzip+aes256gcm  verified(deep)
  2026-07-20T031500Z     app_production      410.1MB  gzip+aes256gcm  verified(structural)
```

The first column is the **selector** — the backup's timestamp label. `latest`
always refers to the most recent backup for the chosen database.

## 2. Verify it first (recommended)

Never trust a backup you haven't verified. Checksums + structural check:

```sh
pgkeeper verify 2026-07-21T031500Z --only app_production -c pgkeeper.yml
```

For maximum confidence, `--deep` restores into a throwaway scratch database and
sanity-checks it (needs privileges to `CREATE DATABASE`):

```sh
pgkeeper verify latest --only app_production --deep -c pgkeeper.yml
```

## 3. Restore

PgKeeper fetches the artifact from a destination (local preferred), reverses the
compression + encryption pipeline, and runs `pg_restore` (custom/directory) or
`psql` (plain) into the target.

**Into a new, empty database** (safest — create it first):

```sh
createdb app_production_restored
pgkeeper restore latest \
  --database app_production \
  --target  app_production_restored \
  -c pgkeeper.yml
```

**Over an existing, non-empty database** — PgKeeper refuses unless you pass
`--force`, which restores with `--clean --if-exists` (existing objects are
dropped first):

```sh
pgkeeper restore latest --database app_production --force -c pgkeeper.yml
```

Useful flags:

| Flag | Meaning |
|------|---------|
| `--database NAME` | Which backed-up database to restore (required if the config has more than one). |
| `--target NAME`   | Target database to restore into (default: same name as the source). |
| `--force`         | Overwrite a non-empty target (`pg_restore --clean --if-exists`). |
| `--jobs N`        | Parallel workers for directory-format restores. |
| `SELECTOR`        | `latest` (default) or a timestamp label / prefix from `pgkeeper list`. |

## 4. Restoring cluster globals (roles, tablespaces)

If you restore onto a **fresh server**, the roles your objects depend on may not
exist yet. Backups taken with `include_globals: true` store a separate
`*-globals-*.sql` artifact. Restore it first, before the database dump:

```sh
# Fetch + materialize the globals artifact, then apply it:
psql -f app_production-globals-2026-07-21T031500Z.sql postgres
```

(Globals are plain SQL. A future PgKeeper release will restore them
automatically; for now apply them manually when moving to a new cluster.)

## 5. After restoring

- Reset/rotate any credentials if this is a copy going to a less-trusted
  environment.
- Run your application's smoke tests against the restored database.
- If this was a disaster-recovery restore, take a fresh backup of the recovered
  database once it's confirmed healthy.
