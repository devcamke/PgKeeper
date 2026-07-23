# PgKeeper — Feasibility, Applicability & Usability Assessment

_An engineering review of how well PgKeeper delivers on its promise: PostgreSQL
backups that are **verifiable, secure, and predictable**, in a **simple workflow**,
to give businesses **assurance, redundancy, and availability**._

This assessment is grounded in a read of the implementation (not just the README):
the backup orchestrator, the tiered verifier, the AES-256-GCM crypto, the retention
safety rails, the web auth layer, the disk preflight, and the test suite. At the
time of writing the unit suite runs **362 tests, 0 failures**.

---

## Verdict

PgKeeper is a **production-grade v1** for what it targets: **scheduled, verifiable,
encrypted logical backups of PostgreSQL with multi-destination redundancy.** The
code is clean, the README's claims are backed by real implementation, and the
safety-critical paths are built the way an experienced operator would want.

There is **one architectural boundary** that decides whether it fits a given
customer, and it should lead every assurance conversation: PgKeeper takes **logical
dumps, not point-in-time recovery (PITR)**. Your recovery point is the last dump.
Details in [Availability](#availability--the-honest-limit) below.

For most SaaS apps, internal tools, and SMB databases, PgKeeper is **deployable
today** and would materially improve backup posture.

---

## Against the five qualities

### Verifiable — the strongest dimension

Verification is **tiered and real** (`lib/pgkeeper/verify.rb`), not a checkbox:

| Tier | What it proves | How |
|---|---|---|
| 1 — checksum | The artifact is byte-identical to what was written | Re-hash every artifact, compare to the SHA-256 in its manifest |
| 2 — structural | The archive is actually readable | `pg_restore --list` (custom/directory) or non-empty SQL (plain) |
| 3 — deep (`--deep`) | The dump genuinely restores | Restore into a throwaway scratch DB, run a sanity query, drop it |

The deep tier restores with `--exit-on-error` / `ON_ERROR_STOP=1`, so a
*partially* broken custom-format dump cannot falsely pass — a subtle detail many
tools get wrong. On success the manifest is stamped with `verified_at` /
`verified_tier`, which then **feeds a retention safety rail** (nothing newer than
your last verified backup is pruned).

This directly closes the industry's most common backup failure — _"the backup
existed but was never restorable."_ **This is the marquee feature.**

### Secure — solid

- **Encryption at rest:** AES-256-GCM (authenticated) using only stdlib OpenSSL,
  streamed in 1 MiB chunks for flat memory, PBKDF2 key stretching, tamper
  detection on decrypt. Encryption happens **before** cloud upload, so third-party
  clouds never see plaintext. GPG is also supported.
- **Dashboard auth is mandatory** — it refuses to boot without credentials —
  uses **constant-time** comparison over SHA-256 digests, binds to `127.0.0.1` by
  default, requires a CSRF token plus explicit confirmation on every mutating
  action, supports **per-caller revocable API tokens** with audit logging, and
  keeps **restores CLI-only** (no destructive action from a stray browser click).
- **Secrets stay out of git** — passwords are `ENV` references via ERB; the
  onboarding wizard never inlines them.

### Predictable — mostly, with caveats

Strong runtime predictability:

- **flock** prevents overlapping cron runs from colliding.
- **Staging + atomic finalize** means a crash never leaves a half-written backup.
- **Wall-clock timeouts** on every `pg_dump` / `pg_restore` / `psql`, so a hung
  child can't wedge a run forever.
- **Disk preflight** estimates live DB size (`pg_database_size`) and refuses to
  start a dump it can't fit.
- **Backup-size anomaly detection** flags the classic silently-shrinking-dump
  signal in the CLI, the log, and the run notification.

Two caveats, stated honestly:

- **No committed `Gemfile.lock`** (it is gitignored). Dependency versions are not
  pinned for deployers, which undercuts reproducible builds — worth reconsidering
  for the Docker/release path, given that predictability is the product's value.
- **Staged (not streamed) pipeline** and **sequential multi-DB dumps** (both
  documented): peak scratch disk is ~2× the largest artifact, and databases in one
  run back up one at a time. Fine for most; it matters at large scale.

### Simple workflow — well done

The on-ramp is genuinely gentle for the target user:

```
pgkeeper connect   # wizard: connection details, LIVE credential test, schedule preview → writes pgkeeper.yml
pgkeeper doctor    # validates tools, config, connectivity, and pg_dump-vs-server version drift
pgkeeper backup    # runs the pipeline, fans out to every destination
```

The dashboard reads the **same** run-history the CLI writes — no second data path.
Exit codes are meaningful throughout (`0` success, `1` partial, `2` total failure),
so cron and CI can react. Documentation is thorough (~1,200 lines across six guides
plus a restore runbook).

---

## Assurance, redundancy, availability

### Redundancy — excellent

Independent fan-out to local + S3-compatible + Dropbox + Google Drive +
SharePoint/OneDrive, each tracked with **per-destination status** — one cloud
outage fails only that destination, not the run. All five backends sit behind one
adapter contract and pass the same shared test suite, so they are provably
interchangeable.

### Assurance — excellent

The evidence trail a business needs for an audit or an RPO/RTO commitment:

- verified-restore proof (above),
- backup-size anomaly detection,
- a **dead-man's-switch** ping that catches a cron which silently never ran,
- email / webhook alerts,
- Prometheus metrics (last run/success timestamp, size, duration, per-DB success).

### Availability — the honest limit

Because PgKeeper takes **logical dumps with no WAL archiving / PITR**, the
**recovery point is the last dump** — a restore loses everything written since
then. If a customer needs seconds-of-data-loss guarantees, PgKeeper alone does not
meet that; they need PITR (pgBackRest / `pg_receivewal`) alongside or instead.

The project documents this clearly and has it on the backlog (PLAN Phase 11), which
is the right call — but it must be **stated up front** in any availability
positioning, not discovered later.

---

## Applicability — who it fits

| Fits well | Reconsider / needs more |
|---|---|
| SaaS & web apps, internal tools, SMB Postgres | Systems needing PITR / near-zero RPO |
| Teams wanting *provable* restorability | Very large DBs (100s of GB+) until the pipeline streams |
| Multi-cloud redundancy requirements | Fleet backup of many clusters from one host (backlogged) |
| Compliance/audit evidence of backup health | |

---

## Recommendations to sharpen the business-assurance story

1. **Lead with the RPO reality.** State plainly — "your data is safe as of the last
   scheduled dump" — and turn the PITR gap into an explicit, upfront SLA statement
   rather than a footnote.
2. **Commit a `Gemfile.lock`** for the release / Docker path so deployed builds are
   reproducible.
3. **Make deep verify a scheduled default in onboarding.** The verified-restore
   proof is the single most compelling differentiator; a weekly `verify --deep`
   belongs in the wizard's suggested schedule.
4. **Publish an RPO/RTO one-pager.** The metrics and history already captured make
   it easy to hand customers concrete numbers.

---

## Summary scorecard

| Quality | Rating | Notes |
|---|---|---|
| Verifiable | Excellent | Three-tier verification incl. real restore; feeds retention rail |
| Secure | Strong | Authenticated encryption before upload; mandatory constant-time dashboard auth |
| Predictable | Good | Locking, atomic finalize, timeouts, preflight; no committed lockfile; staged pipeline |
| Simple workflow | Strong | Wizard + doctor + dashboard; one data path; thorough docs |
| Redundancy | Excellent | Five interchangeable backends, independent per-destination status |
| Assurance | Excellent | Verified restores, anomaly detection, dead-man's switch, metrics |
| Availability | Bounded | Logical dumps only — RPO = last dump; no PITR (documented, backlogged) |

_Bottom line: a well-engineered, honest, deployable backup tool whose standout
strength is proving that backups actually restore. Position it on that strength,
be upfront about the logical-dump RPO boundary, and it delivers real assurance to
the businesses it targets._
