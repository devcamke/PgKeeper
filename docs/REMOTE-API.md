# Triggering backups remotely & choosing destinations

PgKeeper backs up on a schedule, but you can also trigger a run **on demand** —
from your shell, from another host, from a webhook, or from a phone shortcut —
and choose **which destinations** that run ships to. This guide covers all three
surfaces: the CLI, the web API, and the dashboard.

- [Named destinations](#named-destinations)
- [From the CLI](#from-the-cli)
- [From the web API](#from-the-web-api)
- [From the dashboard](#from-the-dashboard)
- [Automating it](#automating-it)

## Named destinations

Every backup fans out to **all** configured `storage:` targets by default — that
is the safe thing and stays the default. To be able to select a subset for a
single run, give a destination a friendly `name:`:

```yaml
storage:
  - type: local
    name: local
    path: /var/backups/pgkeeper/backups

  - type: local          # a NAS is just a local target on a mounted share
    name: nas
    path: /mnt/nas/pgkeeper

  - type: google_drive
    name: gdrive
    folder_id: <%= ENV["GDRIVE_FOLDER_ID"] %>
    credentials_file: /etc/pgkeeper/service-account.json

  - type: sharepoint     # SharePoint / OneDrive via Microsoft Graph
    name: onedrive
    drive_id: <%= ENV["GRAPH_DRIVE_ID"] %>
    tenant_id: <%= ENV["AZURE_TENANT_ID"] %>
    client_id: <%= ENV["AZURE_CLIENT_ID"] %>
    client_secret: <%= ENV["AZURE_CLIENT_SECRET"] %>
```

Names must be unique and must not collide with a storage **type** keyword
(`local`, `s3`, `dropbox`, `google_drive`, `sharepoint`, `memory`). A named
destination is also labelled by its name in run history, notifications, and the
dashboard, so "which copy failed" reads in your vocabulary, not a bucket path.

A destination without a `name:` is still selectable by its **type** (handy when
you have exactly one of that type). List the tokens any run accepts with:

```sh
pgkeeper destinations
#  local            local (local)
#  nas              nas (local)
#  gdrive           gdrive (google_drive)
#  onedrive         onedrive (sharepoint)
```

## From the CLI

Scope a run to one or more destinations with `--destinations` (accepts names or
types, comma-separated or repeated):

```sh
# Everywhere (the default):
pgkeeper backup

# Only the NAS and Google Drive:
pgkeeper backup --destinations nas,gdrive

# One database, cloud only:
pgkeeper backup --only app_production --destinations gdrive,onedrive
```

A destination token that matches nothing fails the run loudly (listing what is
available) rather than silently skipping a copy.

## From the web API

`pgkeeper web` exposes a small JSON API for remote triggering, behind the same
auth as the dashboard. It requires a **token** credential — set `web.auth.token`
or one or more `web.auth.tokens` (browser basic-auth can't reach these
endpoints). Pass the token as a Bearer credential; that header is also what
protects the API from cross-site requests, so these endpoints need no CSRF token
or confirmation checkbox.

### One token per caller (revocable)

Rather than share one secret, issue a **named token per caller** so any one can
be revoked without disrupting the others. Each caller's name is logged with
every action it triggers, so the history shows *who* ran *what*:

```yaml
web:
  auth:
    tokens:
      ci:          <%= ENV["PGKEEPER_TOKEN_CI"] %>
      backups-bot: <%= ENV["PGKEEPER_TOKEN_BOT"] %>
      alice:       <%= ENV["PGKEEPER_TOKEN_ALICE"] %>
```

Each caller sends *its own* token as the Bearer credential — the endpoints and
payloads are identical. To **revoke** one, delete its entry (or unset its
environment variable) and restart the dashboard; every other token keeps
working. A single `token:` and a `tokens:` map may both be present, and a token
also works as a browser basic-auth password (any username). Mint tokens with
`openssl rand -hex 32` (or `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`)
and keep them in the environment, never in the committed config.

### Trigger a backup

```sh
curl -sS -X POST https://pgkeeper.internal/api/actions/backup \
  -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"database":"app_production","destinations":["nas","gdrive"]}'
```

```json
{ "job": { "id": 7, "action": "backup app_production → nas,gdrive",
           "status": "running", "detail": null,
           "started_at": "2026-07-22T03:15:04Z", "finished_at": null } }
```

The call returns immediately with **HTTP 202** and a job id — the backup runs in
the background through the same lock as cron, so it can never start a second
concurrent pipeline. Both fields are optional: omit `database` to back up every
database, omit `destinations` to fan out to all of them.

`database` / `destinations` can also be sent as form-encoded params instead of
JSON, and `destinations` accepts either a JSON array or a comma-separated string.

### Verify and prune

```sh
curl -sS -X POST https://pgkeeper.internal/api/actions/verify \
  -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN" -d 'deep=true'

curl -sS -X POST https://pgkeeper.internal/api/actions/prune \
  -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN" -d 'apply=true'
```

### Poll a job

```sh
curl -sS https://pgkeeper.internal/api/jobs/7 \
  -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN"
```

```json
{ "job": { "id": 7, "action": "backup app_production → nas,gdrive",
           "status": "done", "detail": "1 succeeded, 0 partial, 0 failed",
           "started_at": "2026-07-22T03:15:04Z",
           "finished_at": "2026-07-22T03:16:41Z" } }
```

`status` is `running`, `done`, or `failed`; on failure, `detail` carries the
error (e.g. a destination outage, or a lock held by another run). `GET /api/jobs`
lists recent jobs, and `GET /api/destinations` returns the selectable tokens.

### Endpoint summary

| Method & path                | Purpose                                    |
| ---------------------------- | ------------------------------------------ |
| `POST /api/actions/backup`   | Start a backup (`database`, `destinations`)|
| `POST /api/actions/verify`   | Verify latest backups (`deep`)             |
| `POST /api/actions/prune`    | Enforce retention (`apply`)                |
| `GET  /api/jobs`             | List recent action jobs                    |
| `GET  /api/jobs/<id>`        | One job's status and outcome               |
| `GET  /api/destinations`     | Selectable destination tokens              |
| `GET  /api/status`           | Per-database + per-destination health      |
| `GET  /api/runs`             | Recent run history                         |
| `GET  /api/connections`      | Live-probed database/cluster reachability  |

There is deliberately no config-writing endpoint here: adding a database is a
browser-only flow (CSRF + confirmation) on the Connections page, so a leaked
API token can trigger backups but never rewrite where they point.

All endpoints require the dashboard credential; the `POST` action endpoints
additionally require it to be a **Bearer token**. Put a TLS-terminating reverse
proxy in front for any non-loopback access — see [SECURITY.md](SECURITY.md).

## From the dashboard

The **Actions** page has a "Backup now" form with a database selector and a
checkbox per destination (none checked = all). It still requires the CSRF token
and an explicit confirmation, because a browser form is exactly the thing CSRF
protects against. The page also shows ready-to-copy `curl` recipes for the API.

## Automating it

Because the API is plain authenticated HTTP, anything that can make a request can
trigger a backup — without a PgKeeper install on the calling side:

- **A webhook / CI step** after a migration or a data import.
- **Cron on another host**, when you'd rather centralize scheduling.
- **A phone shortcut** (iOS Shortcuts / Tasker) for an ad-hoc "back up now".
- **A monitoring system**, kicking a fresh backup before risky maintenance.

A minimal "back up before deploy, then wait for it" wrapper:

```sh
#!/usr/bin/env bash
set -euo pipefail
base=https://pgkeeper.internal
auth="Authorization: Bearer $PGKEEPER_WEB_TOKEN"

id=$(curl -fsS -X POST "$base/api/actions/backup" -H "$auth" \
       -H 'Content-Type: application/json' \
       -d '{"destinations":["nas","gdrive"]}' | jq -r '.job.id')

until [ "$(curl -fsS "$base/api/jobs/$id" -H "$auth" | jq -r '.job.status')" != running ]; do
  sleep 5
done
curl -fsS "$base/api/jobs/$id" -H "$auth" | jq '.job | {status, detail}'
```
