# Design: Point-in-Time Recovery (PITR) via WAL archiving

**Status:** proposed (design only — no behavior ships with this document)
**Implements:** [PLAN.md](../PLAN.md) Phase 12
**Owner discussion:** this doc is the reviewable design that must be agreed before
any PITR code lands. It expands the Phase 12 sketch into concrete config, CLI,
module layout, data model, algorithms, failure modes, and a staged rollout.

---

## 1. Why

PgKeeper today takes **logical dumps** (`pg_dump`). Their recovery point is the
last completed dump, so the RPO equals the backup interval — hours to a day. No
amount of tuning changes that: a logical dump is a snapshot, not a change log.

PITR shrinks the recovery point to **any instant you choose**, bounded by the
WAL-shipping interval (seconds-to-minutes). It is the one recovery capability
logical dumps structurally cannot provide, and the top request beyond v1.

**Non-goal / coexistence.** PITR does **not** replace logical dumps. Logical
dumps remain the portable, cross-version, *selective* (single-table, single-DB)
restore path. PITR adds low-RPO, whole-cluster recovery. Both stay first-class;
a cluster can run both.

## 2. The model (and the one architectural shift)

PITR = a periodic **physical base backup** (`pg_basebackup`) + a **continuous
stream of WAL segments**. Recovery restores a base, then replays WAL from that
base up to a target (time, LSN, or named restore point).

**The shift reviewers must sign off on: PITR is cluster-scoped, not
database-scoped.** `pg_dump` runs per database; `pg_basebackup` and WAL cover
the **whole cluster/instance** (all databases, plus globals, physically). Our
config is currently a flat `databases:` list. PITR needs a **cluster identity**
(a `host:port` + credentials + one replication connection). Three options:

| Option | Sketch | Verdict |
|---|---|---|
| **A. `pitr:` on a database entry** | Attach PITR to one `databases:` item; use its connection as "the cluster". | Cheapest, but conflates a logical DB with its cluster; confusing when several `databases:` share a host. |
| **B. Top-level `clusters:`** | New sibling to `databases:`, each a physical cluster with its own `pitr:`. | Cleanest model; larger config change; some duplication of connection fields. |
| **C. Cluster inferred from `host:port`** | Group `databases:` by `host:port`; `pitr:` keyed by that group. | Magic grouping; brittle when creds differ. |

**Recommendation: Option B (`clusters:`)**, because PITR is physically a cluster
operation and pretending otherwise leaks into retention, restore, and the
dashboard. A `clusters:` entry reuses the same connection/`storage`
conventions. Logical `databases:` are unchanged. This is the single biggest
open decision — see §12.

## 3. Config surface

A `clusters:` block; each cluster opts into PITR with a `pitr:` sub-block. All
new keys are optional and validated in `Config` exactly like today (strict
unknown-key rejection, `problem(...)` accumulation — see `config.rb`).

```yaml
clusters:
  - name: app_cluster              # identity in history / catalog / dashboard
    host: db.internal
    port: 5432
    username: <%= ENV["PGKEEPER_REPL_USER"] %>      # a REPLICATION role
    password: <%= ENV["PGKEEPER_REPL_PASSWORD"] %>
    pitr:
      enabled: true
      mode: stream                 # stream (pg_receivewal) | archive (bridge)
      slot: pgkeeper               # replication slot name (stream mode)
      recovery_window: 7d          # keep enough base+WAL to recover 7d back
      base_backup:
        schedule: "daily at 02:00" # its own cadence, separate from dumps
        # format is always tar (-Ft) so it flows through compress+encrypt
      # WAL and base reuse the top-level `storage:`, `compression:`,
      # `encryption:` — same adapters, same crypto, same fan-out. Optional
      # `destinations:` scopes which targets receive PITR data.
```

- **`mode: stream`** — PgKeeper supervises a `pg_receivewal` child (a replication
  slot guarantees gap-free capture). Near-real-time RPO.
- **`mode: archive`** — a bridge for hosts where PgKeeper only sees an archive
  directory populated by the server's `archive_command`. PgKeeper ships whatever
  lands there. RPO = WAL-segment fill/timeout rate.
- **`recovery_window`** — the promise. Retention refuses to prune below it (§7).

## 4. CLI surface

| Command | Purpose |
|---|---|
| `pgkeeper basebackup [--cluster N]` | Take a physical base backup now (mirrors `backup` for dumps). |
| `pgkeeper wal receive --cluster N` | Foreground `pg_receivewal` supervisor (what the daemon runs). Mostly internal. |
| `pgkeeper wal fetch --cluster N --segment X <dest>` | Pull+decrypt+decompress one WAL segment. Used by the restore `restore_command`; also debuggable by hand. |
| `pgkeeper restore --to-time <ts>` / `--to-lsn` / `--to-name` / `--to latest` | PITR restore (see §6). Extends existing `restore`. |
| `pgkeeper verify --pitr [--cluster N]` | Restore a base + replay a bounded WAL range in a scratch cluster; assert consistency (§8). |
| `pgkeeper status` | Adds WAL-archiving lag and current recovery window per cluster. |
| `pgkeeper doctor` | Adds PITR prerequisite checks (§9). |
| `pgkeeper daemon` | Supervises `pg_receivewal` (stream mode) alongside scheduled base backups. |

`schedule install` emits a base-backup timer/cron line per cluster; WAL
streaming is continuous (a daemon/`systemd` service, not a timer).

## 5. Module layout

New code, reusing existing seams (storage adapters, `Compress`, `Crypto`,
`Manifest`, `Subprocess` timeouts, `Lock`, `History`, `Catalog`, `Pruner`):

```
lib/pgkeeper/
  pitr/
    config.rb        # ClusterConfig + PitrConfig value objects
    base_backup.rb   # Backup::Base — drives pg_basebackup -Ft -X none
    receiver.rb      # WAL::Receiver — supervises pg_receivewal (stream mode)
    archiver.rb      # WAL::Archiver — ships segments (both modes) to storage
    wal_fetch.rb     # pulls+decrypts+decompresses one segment (restore_command)
    catalog.rb       # base backups + WAL index per cluster (extends Catalog ideas)
    restore.rb       # PITR::Restore — base fetch → recovery.signal → drive PG
    verify.rb        # PITR::Verify — base + bounded replay in a scratch cluster
    retention.rb     # coupled base+WAL pruning + recovery-window rail
```

Each WAL segment and base tar flows through the **existing** pipeline:
`pg_basebackup`/`pg_receivewal` → package → `Compress` → `Crypto` → `Manifest`
→ storage adapter `upload`. Nothing new in the crypto/compression path; PITR is
another *producer* of artifacts on the same conveyor.

## 6. Data model & storage layout

Reuse the adapter contract (`upload/download/list/delete/healthcheck`, with
retry/backoff — see `storage/base.rb`). Layout per cluster:

```
<cluster>/base/<YYYYMMDDThhmmssZ>/base.tar.<comp>.<enc>   + .manifest.json
<cluster>/wal/<timeline>/<segment-name>.<comp>.<enc>      + .manifest.json (or a batched index)
```

**Base manifest** (extends the existing manifest schema): `kind: "base"`,
`start_lsn`, `stop_lsn`, `timeline`, `server_version`, the embedded
`backup_manifest` from `pg_basebackup` (for `pg_verifybackup`), plus the usual
`checksum`/`compression`/`encryption`.

**WAL index.** Per-segment manifests are simplest but chatty (a busy cluster
emits a 16 MB segment often). Decision (§12): start with **per-segment
manifests** for symmetry with the catalog, and add an optional periodic
**timeline index** object (segment → LSN range → checksum) if the per-segment
list ever becomes a `list()` bottleneck. Segment names already encode
timeline+sequence, so ordering needs no metadata.

**Encryption note.** Each segment is encrypted independently so the restore
`restore_command` can fetch and decrypt *one at a time* without the whole chain.
That's a throughput/latency trade the design accepts for restore simplicity.

## 7. Coupled retention (the correctness-critical part)

A base backup and the WAL needed to recover **from** it are a single unit.
Pruning must never strand a base or break a recovery chain. Extend `Pruner`:

1. **Never delete WAL a surviving base still needs.** For each retained base,
   keep all WAL from its `start_lsn` forward. Concretely: the prunable WAL
   floor = the `start_lsn` of the **oldest base still within the recovery
   window**. Delete WAL older than that floor; keep everything newer.
2. **Recovery-window rail.** Refuse to prune base or WAL if doing so would make
   the reachable recovery horizon younger than `recovery_window`. This composes
   with today's rails (never delete the only/newest/last-verified artifact).
3. **Order of operations.** Prune bases first (respecting the window), recompute
   the WAL floor from survivors, then prune WAL. Never the reverse.
4. **Dry-run first**, like `prune` today; `--apply` to delete; per destination.

A property test (over synthetic base/WAL timelines) asserts: after any prune,
every retained base can still reach `now - recovery_window`, and no retained
base is missing a WAL segment in its chain.

## 8. Restore orchestration (`restore --to <target>`)

The path that must be *exactly* right. Steps:

1. **Resolve target** → time / LSN / named point / `latest`.
2. **Pick the base**: the newest base whose `stop_lsn` (and time) is **≤**
   target. If none, error clearly ("no base backup precedes <target>").
3. **Guard the destination** (reuse logical-restore guards): target data dir must
   be empty (or `--force`), and never restore over a *running* cluster. PITR
   restore is CLI-only, like logical restore — never a web action.
4. **Materialize the base**: fetch → decrypt → decompress → extract tar into the
   target data directory. Verify against the embedded `backup_manifest`
   (`pg_verifybackup`) before proceeding.
5. **Stage recovery** (PG12+): write `postgresql.auto.conf` with
   `restore_command = 'pgkeeper wal fetch --cluster N --segment %f %p'`,
   `recovery_target_time|lsn|name`, and `recovery_target_action = 'promote'`
   (configurable `pause` for inspection); create the `recovery.signal` file.
6. **Drive Postgres**: start the server; it replays WAL via `restore_command`
   until the target, then promotes (or pauses). PgKeeper tails the log, detects
   "consistent recovery state reached" / target reached / timeline switch, and
   reports.
7. **Timeline safety**: refuse an ambiguous target that spans a timeline switch
   unless a timeline is named; surface the new timeline in the report.

The `restore_command` shells back into `pgkeeper wal fetch`, which pulls one
segment from storage and reverses encryption+compression — so the encrypted,
compressed archive is transparent to Postgres. `docs/RESTORE.md` gains a PITR
section with the exact `--to-time` recipe (the 3 a.m. reader's checklist).

## 9. Prerequisites, doctor & observability

**`doctor` / preflight (fail fast, before you rely on it):**
- `wal_level >= replica`,
- `max_wal_senders` > 0 and a usable replication slot (stream mode),
- the connecting role has `REPLICATION`,
- `pg_basebackup` / `pg_receivewal` present and version-matched to the server
  (reuse the existing version-drift check),
- archive destination writable.

**Observability (so "WAL shipping stopped" is loud, not discovered at restore):**
- **WAL lag** = age of the newest archived segment, per cluster.
- **Recovery window** = span from oldest reachable point to now.
- Surface in `status`, the dashboard overview, `metrics`/Prometheus
  (`pgkeeper_wal_archive_lag_seconds`, `pgkeeper_recovery_window_seconds`,
  `pgkeeper_last_base_backup_timestamp`), and the **dead-man's switch** (alarm
  when lag exceeds a threshold).

**Critical operational hazard to document loudly:** in stream mode a replication
slot that PgKeeper stops consuming will make the **primary retain WAL and can
fill its disk**. Mitigations, all in-scope: monitor slot lag and alarm early;
recommend/validate `max_slot_wal_keep_size`; and make a stalled receiver a
first-class alert, not a silent stall.

## 10. Security

- WAL segments and base tars are **encrypted before upload** through the
  existing `Crypto` (AES-256-GCM / GPG) — clouds never see plaintext, same as
  dumps. Key rotation (keyring) applies unchanged.
- Restore's `restore_command` decrypts locally via `pgkeeper wal fetch`; keys
  come from the environment as today, never inlined.
- A dedicated **least-privilege REPLICATION role** (not superuser) for streaming;
  document it in `docs/SECURITY.md` next to the backup role.
- PITR restore stays **CLI-only** (never a dashboard action), like logical
  restore.

## 11. Staged rollout (each stage = one reviewable PR, shippable on its own)

| Stage | Deliverable | Exit criteria |
|---|---|---|
| **0** | This design + `clusters:`/`pitr:` config parsing & `doctor` prereq checks. **No backup behavior.** | Config validates; `doctor` reports PITR readiness; nothing else changes. |
| **1** | `pgkeeper basebackup` via `pg_basebackup -Ft`, through compress+encrypt+manifest+storage+catalog+`list`. | A base backup lands on every destination, is cataloged, and `pg_verifybackup` passes. |
| **2** | WAL archiving: `WAL::Receiver` (streaming, daemon-supervised) + archive bridge + `wal fetch`. | Segments stream to storage gap-free; `wal fetch` round-trips one segment. |
| **3** | Coupled retention + recovery-window rail in `Pruner`. | Property test: no prune ever strands WAL or breaches the window. |
| **4** | `restore --to-time/--to-lsn/--to-name/latest`. | CI: base + WAL → restore to a timestamp → exact rows before target, none after. |
| **5** | `verify --pitr`. | A base with a WAL gap **fails** verify; an intact chain passes. |
| **6** | Observability: WAL lag + recovery window in status/dashboard/metrics/dead-man's. | Stopped streaming raises an alert within one threshold interval. |
| **7** | Docs: `RESTORE.md` PITR runbook + `RPO-RTO.md` update. | A reader can execute a `--to-time` restore from the runbook alone. |

Stages 1–2 are independently useful (physical base backups + archived WAL) even
before restore automation lands, so value ships incrementally.

## 12. Open decisions (resolve in review before Stage 0)

1. **Cluster identity** — `clusters:` (recommended, §2 Option B) vs `pitr:` on a
   database entry vs `host:port` grouping. Everything downstream keys off this.
2. **WAL metadata** — per-segment manifests (start here) vs a batched timeline
   index (add later if `list()` gets heavy).
3. **WAL compression** — reuse `compression:` for segments, or a fixed fast codec
   (lz4/zstd) since segments are hot-path and small? Leaning: honor
   `compression:` but default segments to zstd/none for latency.
4. **`recovery_target_action`** default — `promote` (usable immediately) vs
   `pause` (inspect before committing). Leaning `promote`, with a `--pause` flag.
5. **Multiple clusters** — support N clusters in one config from day one (the
   `clusters:` list makes this free) or scope Stage 0–4 to a single cluster.

## 13. Testing strategy

Dockerized live Postgres (the existing integration harness), per PLAN.md:
seed → base backup → generate WAL by writing rows with recorded
timestamps/LSNs → `restore --to-time`/`--to-lsn` → **assert the cluster contains
exactly the rows written before the target and none after**. Plus: gap-in-WAL
detection fails `verify --pitr`; retention property test never strands WAL;
`pg_receivewal` supervision restarts cleanly and resumes without a gap; and unit
tests for the retention floor math and target/base selection with the in-memory
storage backend.
