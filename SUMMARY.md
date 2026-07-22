# Branch summary — cloud storage backends & reliability hardening

Everything on `claude/code-review-checklist-m9kdhm` (PR #15): five commits that
closed the Phase 4 cloud-provider gap and fixed two upload/scale hazards
surfaced by a four-dimension review.

| Metric | Value |
|---|---|
| Commits | 5 |
| Files touched | 26 |
| Lines | +2,142 / −66 |
| Tests | 256 runs · 0 failing |
| New tests | +41 |
| RuboCop | 0 offenses (89 files) |

## Where it started

The branch opened with a review across four dimensions — **complete, secure,
usable, scalable**. The verdict: a genuinely well-built v1.0 (clean code, green
suite, strong web-auth and crypto), with three concrete gaps worth fixing — two
scaling hazards in the upload path, and a completeness gap where **Google Drive,
Dropbox, and SharePoint were promised in the plan but never built**. This branch
resolves all three.

## What shipped, commit by commit

### `98fd96f` — S3 multipart upload & size-aware preflight *(hardening)*

- A single `put_object` capped uploads at S3's **5 GiB** limit — real dumps
  failed outright. Now routed through the SDK transfer manager: automatic
  multipart above 100 MiB, streamed part-by-part with flat memory.
- The disk preflight only enforced a fixed 100 MiB floor. Extracted a
  `Preflight` object that estimates live DB size (`pg_database_size`) and
  reserves a multiple of it, so a run is refused *before* it fills the disk
  mid-dump.
- Tests: **+4** (215 → 219)

### `73879df` — Dropbox backend *(feature)*

- Dropbox HTTP API v2 directly — **no SDK**. Files above the 150 MB
  single-request ceiling stream through an upload session.
- Auth by refresh-token triple (exchanged per run) or a long-lived access token.
- Tests: **+12** (219 → 231)

### `e1789f8` — Google Drive backend *(feature)*

- Drive REST API v3 directly, **signing its own service-account JWT** (RS256 via
  OpenSSL — no `googleauth` gem, no `base64` gem).
- Drive is ID-based, so each artifact is stored as a file named for its full
  path; large files use a resumable session.
- Tests: **+14** (231 → 245)

### `3de0f52` — SharePoint / OneDrive backend *(feature)*

- Microsoft Graph with an app-only client-credentials token. Graph addresses
  items by path, so keys map straight onto a drive — no ID dance.
- Upload sessions for large files; recursive `delta` query for listing.
  **Completes the Phase 4 set.**
- Tests: **+11** (245 → 256)

### `0c94d60` — CI Ruby pin fix *(fix)*

- CI pinned Ruby `4.0.6` — a version that doesn't exist, so `mise` could never
  provision it and CI never ran. Pinned to `3.3.6`, the version the suite is
  proven green on.

## Storage fan-out, now complete

| Backend | Status |
|---|---|
| Local filesystem | prior |
| S3-compatible | prior · multipart added |
| Dropbox | new |
| Google Drive | new |
| SharePoint / OneDrive | new |

All five sit behind one adapter interface and pass the same shared storage
contract — every backend is provably interchangeable, fanned out independently
with per-destination status. The three new cloud adapters are SDK-free
(Net::HTTP + OpenSSL) and tested against stateful in-memory HTTP stubs.

## Verification

- **Test suite:** 256 runs · 642 assertions · 0 failures · 0 errors
- **Skips:** 15 (environment-gated: live PostgreSQL, `zstd`, `gpg`)
- **RuboCop:** 0 offenses · 89 files

## Files changed

| Area | Path | Δ |
|---|---|---|
| New adapter | `storage/dropbox.rb` | +303 |
| New adapter | `storage/google_drive.rb` (+ `service_account.rb`) | +359 |
| New adapter | `storage/sharepoint.rb` (+ `app_token.rb`) | +320 |
| Hardening | `storage/s3.rb` | +24 / −4 |
| Hardening | `preflight.rb` (extracted) · `orchestrator.rb` | +84 / −19 |
| Wiring | `storage.rb` · `config.rb` | +70 / −7 |
| Tests | 4 new adapter suites · `test_config` · `test_preflight` | +699 / −17 |
| Docs / CI | PROVIDERS · STORAGE · README · CHANGELOG · CI · example config | +283 |

Line counts are approximate groupings of the branch diff (26 files, +2,142 / −66
total).

## Still open (pre-existing, not regressions)

- **Staged, not piped, pipeline** — dump → compress → encrypt each stage writes
  a file; peak scratch is ~2× the largest artifact. Piping would cut it.
- **Sequential multi-DB dumps** — databases in one run back up one at a time
  (directory-format dumps do use `pg_dump --jobs` internally).
- Handled on this branch: the README cloud-provider oversell and the CI Ruby
  pin.
