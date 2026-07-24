# Deploying PgKeeper with Docker Compose on an existing server

This folder is a ready-to-edit deployment for the common real-world case: a server that
already runs several applications with their own PostgreSQL databases, and you want one
PgKeeper container that

- **backs them all up automatically** on a schedule (the in-process `daemon`), and
- **lets you trigger jobs manually** — from the web dashboard, the CLI, or the JSON API.

It differs from `../docker-compose.example.yml` in that it does **not** start a Postgres
of its own; it connects to the databases you already have.

```
deploy/
├── docker-compose.yml   # the PgKeeper service (daemon + dashboard)
├── pgkeeper.yml         # config template: databases, schedules, storage, web
├── .env.example         # secrets template → copy to .env
├── KAMAL.md             # alternative: push-button deploys from your workstation
└── README.md            # this file
```

> Prefer deploying from your workstation instead of running compose on the server?
> [KAMAL.md](KAMAL.md) deploys the same container with [Kamal](https://kamal-deploy.org)
> — builds locally, ships over SSH, with releases and rollbacks. Pick one mechanism,
> not both. The rest of this file covers the compose path.

## 1. Prerequisites

- Docker with the compose plugin on the server.
- This repository cloned on the server (the compose file builds the image from `..`).
- The image's `pg_dump` must be **at least as new** as your newest Postgres server —
  `pg_dump` refuses to dump a newer server. The Dockerfile installs Debian's
  `postgresql-client`; pin the PGDG repo in the Dockerfile if your servers are newer.
  (`pgkeeper doctor` in step 5 checks this for you.)

## 2. Create a backup role in Postgres

Run once per Postgres instance (as a superuser):

```sql
CREATE ROLE backup_user LOGIN PASSWORD 'choose-a-strong-password';
GRANT pg_read_all_data TO backup_user;   -- PostgreSQL 14+
```

On Postgres ≤ 13 (no `pg_read_all_data`), grant `SELECT` on the schemas involved, or use
a superuser role. Note `include_globals: true` (dumping roles/tablespaces via
`pg_dumpall --globals-only`) needs a superuser; set it to `false` if `backup_user` isn't one.

## 3. Make the databases reachable from the container

Pick the case that matches each application:

**A. Postgres runs on the host** (installed via apt/systemd, or a container that
publishes 5432 on the host): keep `host: host.docker.internal` in `pgkeeper.yml` — the
compose file maps that name to the host. On Linux you must also let Postgres accept
connections from the Docker bridge:

```
# postgresql.conf
listen_addresses = 'localhost,172.17.0.1'    # or '*'

# pg_hba.conf — allow the Docker bridge subnet
host  all  backup_user  172.16.0.0/12  scram-sha-256
```

Reload Postgres afterwards (`systemctl reload postgresql`).

**B. Postgres runs in another compose project**: don't route through the host — join
that project's network. Uncomment the `networks:` blocks in `docker-compose.yml`, set
the real network name (`docker network ls`), and use the Postgres **service name** as
`host:` for that database entry in `pgkeeper.yml`. No `pg_hba.conf` change needed.

## 4. Configure

```sh
cd deploy
cp .env.example .env && chmod 600 .env
```

- **`.env`** — fill in the `backup_user` password(s) and generate a dashboard token
  (`openssl rand -hex 32`).
- **`pgkeeper.yml`** — replace the `app1`/`app2` entries with your real databases; one
  entry per application database. Adjust the global `schedule:` and any per-database
  overrides. Add off-site storage (S3/NAS/…) when ready — and turn on `encryption:`
  before shipping dumps to any cloud.
- **`docker-compose.yml`** — keep the `environment:` block in sync with the env vars
  your `pgkeeper.yml` references (one line per `<%= ENV[...] %>`).

## 5. Validate, then start

```sh
docker compose build
docker compose run --rm pgkeeper doctor    # tools, config, DB reachability, storage health
docker compose up -d
docker compose logs -f pgkeeper            # watch the daemon schedule its first runs
```

`doctor` must be clean (or have only warnings you understand) before `up`. The container
now runs every schedule in `pgkeeper.yml` — backups, weekly deep verify, daily prune —
and restarts with the server (`restart: unless-stopped`).

## 6. Using it

**Dashboard** — published on the host's loopback only. From your workstation:

```sh
ssh -L 8321:127.0.0.1:8321 you@server
# then browse http://localhost:8321 — any username, the PGKEEPER_WEB_TOKEN as password
```

Overview (per-database health, next runs), run timeline, retention preview, and an
**Actions** page to trigger backup / verify / prune / doctor manually. For permanent
remote access, put your reverse proxy with TLS in front instead of the SSH tunnel.

**Manual runs from the CLI** (same lock as the scheduler, so nothing can overlap):

```sh
docker compose run --rm pgkeeper backup                      # everything, now
docker compose run --rm pgkeeper backup --only app1          # one database
docker compose run --rm pgkeeper status                      # last run per database
docker compose run --rm pgkeeper list                        # stored backups
docker compose run --rm pgkeeper verify --deep               # prove restorability
docker compose run --rm pgkeeper prune                       # dry-run the retention policy
```

**Remote-trigger API** (scripts, webhooks, phone shortcuts — see `../docs/REMOTE-API.md`):

```sh
curl -X POST http://localhost:8321/api/actions/backup \
  -H "Authorization: Bearer $PGKEEPER_WEB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"database":"app1"}'          # → {"job":"<id>"} — poll GET /api/jobs/<id>
```

**Restore** (deliberately CLI-only; runbook in `../docs/RESTORE.md`):

```sh
docker compose run --rm pgkeeper restore latest --database app1 --target app1_restored
```

## 7. Day-2 notes

- **Test a restore now**, not on the day you need it: `verify --deep` runs weekly by
  this config, but do one full `restore` into a scratch database once after setup.
- **Enable a failure alert** — uncomment a `notifications:` channel in `pgkeeper.yml`
  (email, Slack/webhook, or a dead-man's-switch ping) so a silently failing backup
  can't go unnoticed.
- **Off-host copies**: a backup that only lives on the same server as the databases
  disappears with the server. Add an S3-compatible or NAS destination early.
- **Upgrading PgKeeper**: `git pull && docker compose build && docker compose up -d`.
  Backups, run history, and locks live in the `backups` volume and survive rebuilds.
- **Where the data is**: named volume `deploy_backups`
  (`docker volume inspect deploy_backups`); switch to a bind mount in
  `docker-compose.yml` if you want it on a specific disk.
