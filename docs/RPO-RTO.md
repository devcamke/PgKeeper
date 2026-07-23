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

PgKeeper takes **logical dumps** (`pg_dump` / `pg_dumpall`). It does **not** ship
write-ahead logs (WAL) and does **not** do point-in-time recovery (PITR).

**Your recovery point is your last completed dump.** If you back up daily at 03:15
and the database is lost at 15:00, you recover the 03:15 state and lose the writes
in between.

That is a deliberate v1 boundary, not a bug. It keeps PgKeeper simple, portable,
and dependency-light. If you need seconds-of-loss recovery, see
[When you need better than this](#when-you-need-better-than-this).

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

## When you need better than this

If your RPO must be **minutes or seconds** (financial ledgers, order systems, any
system where a day — or an hour — of lost writes is unacceptable), logical dumps
alone are not enough. Add continuous WAL archiving / PITR:

- [`pg_receivewal`](https://www.postgresql.org/docs/current/app-pgreceivewal.html)
  for streaming WAL, or
- a PITR-capable tool such as
  [pgBackRest](https://pgbackrest.org/) or
  [Barman](https://pgbarman.org/).

A common, robust pattern is **both**: PITR for a tight RPO, and PgKeeper for
verifiable, portable, encrypted logical dumps fanned out to independent
destinations as a second, provably-restorable line of defense. PITR guidance is on
the PgKeeper roadmap (PLAN.md, Phase 11).

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
