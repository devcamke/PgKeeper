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

## Point-in-time recovery (PITR)

Logical restore (above) brings back **one database** from a dump; its recovery
point is that dump. **PITR** rebuilds a **whole cluster** from a physical base
backup plus the archived write-ahead log (WAL), recovered to *any moment you
choose* — the last-known-good instant before a bad migration, an errant
`DELETE`, or a crash. This is the section to follow when the target is a
timestamp, not a nightly snapshot.

PITR is **cluster-scoped**, configured under a top-level `clusters:` entry (not
the logical `databases:` list) with `pitr.enabled: true`. See
[PITR-DESIGN.md](PITR-DESIGN.md) for the model and
[../config/pgkeeper.example.yml](../config/pgkeeper.example.yml) for the config.

### How the pieces get there (the ongoing half)

A restore is only possible if two things have been running *before* the
disaster. Neither is a recovery-day step — confirm they exist, don't start them
now:

- **Periodic base backups** — a physical snapshot of the cluster:
  ```sh
  pgkeeper basebackup --cluster main -c pgkeeper.yml
  ```
  Scheduled from `pitr.base_backup.schedule`; each lands on every destination,
  compressed + encrypted, and is cataloged as `kind: base`.
- **Continuous WAL archiving** — every completed 16 MB segment shipped to
  storage, so recovery can replay past the base. Two supported paths:
  ```sh
  # (a) archive bridge: the server's archive_command hands PgKeeper one segment
  #     archive_command = 'pgkeeper wal archive-file --cluster main %p %f'
  # (b) spool drain: run pg_receivewal into a spool dir, PgKeeper ships completed
  #     segments and deletes each once it is safely on every destination
  pgkeeper wal archive --spool /var/spool/pgkeeper-wal --cluster main -c pgkeeper.yml
  ```
  (`pitr.mode` records intent; a PgKeeper-supervised `pg_receivewal` streamer is
  on the roadmap — for now run it yourself and drain its spool.)

The recovery horizon you can reach is *newest base → end of archived WAL*.

### 1. Confirm you can actually recover — before you rely on it

Two catalog-only checks, no scratch server needed. **Run these first.**

```sh
# Is the WAL an unbroken chain from the newest base forward? A single missing
# segment caps how far a restore can replay — this finds it now, not at 3 a.m.
pgkeeper verify --pitr --cluster main -c pgkeeper.yml

# How fresh is the archived WAL, and how far back does the window actually reach?
pgkeeper status -c pgkeeper.yml
```

`verify --pitr` fails loudly on a gap (naming the missing segment), on a base
with no recorded start segment, or when no WAL is archived at or after the base.
`status` prints, per cluster, the **WAL lag** (age of the newest segment) and
the **recovery window** (oldest base → now) — if lag is high, archiving has
stalled and your reachable target is older than you think. `pgkeeper doctor`
covers the prerequisites (`wal_level`, `max_wal_senders`, the `REPLICATION`
role, matched `pg_basebackup`/`pg_receivewal`).

### 2. Choose the recovery target

| Target flag | Recovers to | Use when |
|---|---|---|
| `--to-time "2026-07-23 14:55:00+00"` | just before that instant | you know *when* it went wrong |
| `--to-lsn 0/1A2B3C48` | that write-ahead position | you have an exact LSN (e.g. from logs) |
| `--to-name my_restore_point` | a named `pg_create_restore_point` | you tagged a safe point beforehand |
| `--to latest` | the end of all archived WAL | you want maximum recovery (a total loss) |

Pick the **last good moment**. For a bad 15:00 migration, target `14:59:59+00` —
recovery stops *before* the target, so aim just ahead of the damage.

### 3. Stage the recovery data directory

Point `--data-dir` at an **empty** directory (PgKeeper refuses a non-empty one
without `--force`, and never touches a running server):

```sh
pgkeeper restore --cluster main \
  --data-dir /var/lib/postgresql/recovered \
  --to-time "2026-07-23 14:55:00+00" \
  --restore-bin /usr/local/bin/pgkeeper \
  -c pgkeeper.yml
```

This picks the newest base at or before the target, extracts it into the data
directory, and writes the recovery configuration:

- `restore_command` — fetches each WAL segment via `pgkeeper wal fetch`,
  reversing compression + encryption transparently to Postgres,
- `recovery_target_time` (or `_lsn` / `_name`) and `recovery_target_action`
  (`promote` by default; `--action pause` to inspect before committing), and
- the `recovery.signal` file that puts the server into recovery on next start.

### 4. Provide the cluster config, then start Postgres

The base backup contains the **data**, but on Debian/Ubuntu the *config*
(`postgresql.conf`, `pg_hba.conf`) lives under `/etc/postgresql/...`, outside the
data directory — so it won't be in the backup. Put working copies in place, then
start the server **as the `postgres` user**:

```sh
sudo -u postgres pg_ctl -D /var/lib/postgresql/recovered start
```

Postgres replays WAL through the `restore_command` until it reaches the target,
then promotes (or pauses). Watch it get there:

```sh
tail -f /var/lib/postgresql/recovered/log/*.log
# look for: "starting point-in-time recovery to ..."
#           "consistent recovery state reached"
#           "recovery stopping before ... <target>"
#           "database system is ready to accept connections"
```

If recovery **pauses** (`--action pause`), inspect the data, then finish with
`SELECT pg_wal_replay_resume();` to promote.

### 5. Confirm, then re-baseline

- Connect and verify the data is exactly as of your target — the bad change is
  gone, everything before it is present.
- Reset/rotate credentials if this cluster is going somewhere less trusted.
- **Take a fresh base backup of the recovered cluster** once it's healthy: it is
  on a new timeline, and your next recovery should start from it.

### The 3 a.m. checklist

- **`restore_command` runs as `postgres`.** The `--restore-bin` path, the config
  file, the WAL storage, and any encryption passphrase in the environment must
  all be reachable by that user — test `sudo -u postgres pgkeeper wal fetch ...`
  for one segment if a restore stalls fetching WAL.
- **`--to-time` format** is a plain timestamp with an offset
  (`2026-07-23 14:55:00+00`) — what Postgres expects; ISO-8601 with a `T` is
  rejected.
- **Recovery stops *before* the target**, so aim just past the last good write.
- **Provide `postgresql.conf`/`pg_hba.conf`** before starting if your packaging
  keeps them outside the data directory.
- **PITR restore is CLI-only** — never a dashboard action.
