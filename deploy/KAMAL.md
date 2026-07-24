# Deploying PgKeeper with Kamal

An alternative to running `docker compose` on the server yourself:
[Kamal](https://kamal-deploy.org) builds the image on your workstation, pushes it to a
registry, and boots it on your server(s) over SSH — with releases, rollbacks, and log
access from your machine. Same container, same config contract as the compose kit:

| Piece | Compose kit | Kamal |
|-------|-------------|-------|
| Orchestration file | `deploy/docker-compose.yml` | `config/deploy.yml` |
| App config | `deploy/pgkeeper.yml` (bind-mounted) | `deploy/pgkeeper.yml`, synced to `/etc/pgkeeper/pgkeeper.yml` on the host by `.kamal/hooks/pre-deploy` |
| Secrets | `deploy/.env` | your shell env (or a password manager), declared in `.kamal/secrets` |
| Build | on the server | on your workstation (or `builder.remote`), pushed to a registry |

Use Kamal when you deploy from a workstation/CI and want push-button releases; use the
compose kit when you'd rather keep everything on the server. Don't run both for the same
databases.

## 1. Prerequisites

- `gem install kamal` on your workstation (Ruby 3.2+), plus Docker for building.
- Root SSH access to the server (or set `ssh.user` in `config/deploy.yml`).
- A container registry you can push to (Docker Hub, GHCR, …).
- The same database-side setup as the compose kit — a `backup_user` role and
  reachability from containers (`deploy/README.md`, steps 2–3). The Kamal config ships
  the same `host.docker.internal:host-gateway` mapping for host Postgres.

## 2. Configure

Three places, no secrets in any of them:

- **`config/deploy.yml`** — set your `image:` (registry user), the server address under
  `servers.web.hosts`, `registry:`, and `builder.arch` to match the server. Keep the
  `env.secret` list in sync with the ERB references in your `deploy/pgkeeper.yml`.
- **`deploy/pgkeeper.yml`** — your databases and schedules, exactly as in the compose
  walkthrough (`deploy/README.md`, step 4). The pre-deploy hook copies this file to
  `/etc/pgkeeper/pgkeeper.yml` on every host each deploy.
- **`.kamal/secrets`** — already reads your environment; export the values before
  deploying (or wire up a password-manager adapter, see the comments in that file):

```sh
export KAMAL_REGISTRY_PASSWORD=...   # registry access token
export PGKEEPER_APP1_PASSWORD=... PGKEEPER_APP2_PASSWORD=...
export PGKEEPER_WEB_TOKEN=$(openssl rand -hex 32)
```

## 3. First deploy

```sh
kamal setup        # installs Docker on the host if needed, pushes secrets, deploys
kamal app logs -f  # watch the daemon schedule its first runs
```

Then validate from your workstation — `doctor` checks tools, config, database
reachability, and storage health from *inside* the deployed environment:

```sh
kamal app exec 'doctor'
```

Subsequent releases (image, config, or secrets changed) are all just:

```sh
kamal deploy
```

Every deploy re-syncs `deploy/pgkeeper.yml` (via the hook) and boots a fresh container,
so config edits take effect on deploy. `kamal rollback` returns to the previous release;
backups, run history, and locks live in the `pgkeeper_backups` volume on the host and
survive both.

## 4. Using it

```sh
kamal app exec 'backup'                    # manual run, everything
kamal app exec 'backup --only app1'        # one database
kamal app exec 'status'                    # last run per database
kamal app exec 'verify --deep'             # prove restorability
kamal app logs -f                          # daemon + dashboard logs
```

The dashboard stays loopback-only on the server, same as the compose kit:

```sh
ssh -L 8321:127.0.0.1:8321 root@your-server
# browse http://localhost:8321 — any username, PGKEEPER_WEB_TOKEN as password
```

To serve it on a real domain with automatic TLS instead, switch the role to kamal-proxy —
see the commented `proxy:` block in `config/deploy.yml` (it health-checks the
unauthenticated `/healthz` endpoint; dashboard auth still applies to everything else).

The remote-trigger API and restore runbook work exactly as described in
`deploy/README.md` step 6 and `docs/REMOTE-API.md` / `docs/RESTORE.md`.

## Notes

- **The hook needs SSH + write access to `/etc/pgkeeper`** on each host (default user
  root; override with `PGKEEPER_DEPLOY_SSH_USER`). Prefer to manage the file yourself?
  Delete `.kamal/hooks/pre-deploy` and copy the config over manually — the bind mount in
  `config/deploy.yml` is the only contract.
- **`kamal app exec` runs a fresh one-off container** with the same image, env, and
  volumes — it goes through the same entrypoint and takes the same job locks as the
  daemon, so a manual backup can never overlap a scheduled one.
- **Multiple servers**: add hosts under `servers.web.hosts` and each gets the full
  stack — only do that if each host backs up *different* databases (split the config per
  destination with `config/deploy.<dest>.yml`); two daemons with identical configs would
  duplicate every backup.
