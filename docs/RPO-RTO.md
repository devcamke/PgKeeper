# RPO / RTO — what PgKeeper guarantees, in plain terms

Two numbers decide whether any backup tool fits your business:

- **RPO (Recovery Point Objective)** — how much *data* you can afford to lose,
  measured as a window of time. "RPO = 24h" means a disaster may cost you up to a
  day's worth of writes.
- **RTO (Recovery Time Objective)** — how long you can afford to be *down* while
  you restore.

This page states, honestly, what PgKeeper delivers on both — so you can set an SLA
you can actually keep.

---

## The one thing to understand first

PgKeeper has **two** recovery modes, and your RPO depends on which one you run:

- **Logical dumps** (`pg_dump` / `pg_dumpall`) — the default. Portable,
  cross-version, per-database. **Your recovery point is your last completed
  dump:** back up daily at 03:15, lose the database at 15:00, and you recover the
  03:15 state — the writes in between are gone. RPO = your backup interval.
- **Point-in-time recovery (PITR)** — physical base backups plus continuous WAL
  archiving, letting you recover a whole cluster to *any instant* in the retained
  window. RPO shrinks to **seconds-to-minutes** (how fast WAL ships), not hours.

Most deployments want **both**: frequent, verifiable logical dumps as the
portable line of defense, and PITR when a day — or an hour — of lost writes is
unacceptable. The rest of this page covers each; pick per the loss your business
can tolerate. PITR setup lives in [PITR-DESIGN.md](PITR-DESIGN.md); recovery
steps in the [restore runbook](RESTORE.md#point-in-time-recovery-pitr).

---

## Your RPO = your backup interval

RPO is set entirely by **how often you schedule `pgkeeper backup`**, plus a small
margin for how long a dump takes.

| Backup schedule | Worst-case data loss (RPO) |
|---|---|
| Hourly | up to ~1 hour + dump duration |
| Every 6 hours | up to ~6 hours + dump duration |
| Daily (`daily at 03:15`) | up to ~24 hours + dump duration |
| Weekly | up to ~7 days + dump duration |

Pick the interval from the table that matches the loss your business can tolerate,
then set it in `pgkeeper connect` or the `schedule:` key. Two guardrails make the
interval you *chose* the interval you actually *get*:

- **Dead-man's switch** — a monitor is pinged on every run, so a cron that
  silently stops (the classic "we thought we had backups") is caught, not
  discovered during a disaster.
- **Backup-size anomaly detection** — a dump that suddenly shrinks (a broken
  export that still "succeeds") is flagged loudly, so a bad backup doesn't quietly
  become your recovery point.

---

## PITR: RPO in seconds, and a whole-cluster recovery point

When the interval table above isn't tight enough, turn on PITR for the cluster
(a `clusters:` entry with `pitr.enabled`). Now two things run continuously:
periodic **base backups** (`pgkeeper basebackup`) and **WAL archiving** — every
completed 16 MB segment shipped to storage as it fills.

- **RPO = your WAL-shipping lag**, typically seconds to a couple of minutes, not
  your base-backup interval. Stream WAL with `pg_receivewal` and a replication
  slot (gap-free, near-real-time) and let PgKeeper drain the spool, or bridge the
  server's `archive_command` through `pgkeeper wal archive-file` (RPO = one
  segment's fill/timeout). Either way you recover to *any* instant in the window,
  so the recovery point is a moment you choose — not the last snapshot.
- **The recovery window** — how far back you can go — reaches back to the
  **oldest retained base** (you restore a base at or before your target and
  replay forward), held open by `pitr.recovery_window` (retention refuses to
  prune base or WAL below it). `pgkeeper status` and the
  `pgkeeper_recovery_window_seconds` metric report it as *oldest base → now*.

Three guardrails keep the PITR RPO you *chose* the one you actually *get*, all
surfaced in `pgkeeper status`, the dashboard, and `pgkeeper metrics`:

- **WAL lag** (`pgkeeper_wal_archive_lag_seconds`) — the age of the newest
  archived segment. If shipping stalls, this climbs and your real RPO widens.
- **Dead-man's switch** (`pgkeeper_wal_archive_stalled`) — set `pitr.max_lag`
  (e.g. `15m`) and a stalled archiver flags the cluster red and trips the metric,
  so "WAL shipping stopped" is an alert, not a restore-day discovery.
- **Chain integrity** — `pgkeeper verify --pitr` confirms the archived WAL is an
  unbroken run from the newest base, so a gap that would cap recovery is caught
  ahead of time.

RTO for PITR is base-fetch + WAL replay to the target; replay time grows with how
much WAL accumulated since the chosen base, so a **more frequent base-backup
cadence trades storage for a shorter replay** (and thus a shorter RTO). The full
procedure is the [PITR runbook](RESTORE.md#point-in-time-recovery-pitr).

## Your RTO = fetch + restore + verify-first confidence

RTO with PgKeeper is the time to:

1. **fetch** the artifact from a destination (local disk is fastest; cloud adds
   download time proportional to size and bandwidth),
2. **reverse the pipeline** (decrypt + decompress — automatic, driven by the
   manifest), and
3. **`pg_restore` / `psql`** into the target database (parallelizable for
   directory-format dumps via `--jobs`).

Drivers of RTO, and how to shrink each:

| Driver | Lever |
|---|---|
| Download time | Keep a **local** destination alongside the cloud (fan-out is independent) |
| Restore time | Use `format: custom`/`directory` + `restore --jobs N` |
| "Will it even restore?" uncertainty | **Verify ahead of time** (below) — so restore day holds no surprises |

The [restore runbook](RESTORE.md) is written to be followed at 3 a.m. under
pressure.

---

## Verify *before* the disaster — the RTO you can trust

The worst RTO is an infinite one: the restore fails and you have nothing. PgKeeper
is built so that never happens by surprise. Run verification on a schedule, not on
recovery day:

```sh
# Cheap, frequent: checksum + "is this a readable archive?"
pgkeeper verify

# Weekly (recommended): actually restore into a throwaway scratch DB and query it
pgkeeper verify --deep
```

`verify --deep` restores with strict error handling (`--exit-on-error` /
`ON_ERROR_STOP=1`), so a partially-corrupt dump **fails verification** instead of
falsely passing. A passing deep verify stamps the backup as verified, which also
protects it from pruning. **A weekly deep verify turns "we have backups" into "we
have backups that provably restore" — the real RTO guarantee.**

### Schedule a weekly deep verify

Alongside the backup schedule that `pgkeeper schedule install` emits, add a weekly
deep-verify line. Crontab example (Sundays at 04:30, flock-guarded like the backup
lines):

```cron
30 4 * * 0 /usr/bin/flock -n /var/backups/pgkeeper/.verify.lock \
  pgkeeper verify --deep --config /etc/pgkeeper/pgkeeper.yml >> /var/backups/pgkeeper/pgkeeper.log 2>&1
```

Deep verify needs credentials that can `CREATE DATABASE` (it restores into a
scratch database and drops it); see [SECURITY.md](SECURITY.md).

---

## Redundancy and availability of the backups themselves

RPO/RTO assume the backup exists when you reach for it. PgKeeper hardens that:

- **Independent multi-destination fan-out** (local + S3-compatible + Dropbox +
  Google Drive + SharePoint/OneDrive). One destination being down fails only that
  destination — the run still succeeds elsewhere, with per-destination status.
- **Retention safety rails** — the newest backup is never pruned, a policy can
  never delete everything, and nothing newer than your last *verified* backup is
  removed.

Recommended posture for a real availability story: **at least one local and one
off-site destination**, so a site-level failure never takes your only copy with
it.

---

## When you need better than the interval

If your RPO must be **minutes or seconds** (financial ledgers, order systems, any
system where a day — or an hour — of lost writes is unacceptable), logical dumps
alone are not enough — turn on PgKeeper's **native PITR** (Phase 12): base
backups, continuous WAL archiving, and `restore --to-time/--to-lsn/--to-name`,
with lag monitoring and chain verification built in. See
[PITR: RPO in seconds](#pitr-rpo-in-seconds-and-a-whole-cluster-recovery-point)
above and [PITR-DESIGN.md](PITR-DESIGN.md).

The robust posture is **both modes together**: PITR for a tight, whole-cluster
RPO, and logical dumps for verifiable, portable, encrypted, per-database
restores fanned out to independent destinations — each covering the other's
blind spot. If you already run a dedicated PITR appliance such as
[pgBackRest](https://pgbackrest.org/) or [Barman](https://pgbarman.org/), keep
it; PgKeeper's logical dumps still add a cross-version, off-site, provably-
restorable second line.

---

## Set your SLA

Fill this in for your deployment and publish it — it is the assurance your
stakeholders actually want:

> Backups run **every `<interval>`**, to **`<N>` independent destinations**
> (`<local + off-site>`). Worst-case data loss (RPO) is **`<interval>`**.
> Restores are proven weekly with `verify --deep`; expected recovery time (RTO)
> for a `<size>` database is **`<measured minutes>`**.

See also: [ASSESSMENT.md](ASSESSMENT.md) for the full engineering review, and
[RESTORE.md](RESTORE.md) for the step-by-step recovery runbook.
