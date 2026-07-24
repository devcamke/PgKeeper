# PgKeeper Security Guide

Backups concentrate everything sensitive about your database into portable
files. This guide covers the least-privilege database role, secret handling,
encryption, artifact permissions, and the web dashboard's security model.

## Least-privilege backup role

Never dump as a superuser. Create a dedicated role that can read everything
but change nothing:

```sql
CREATE ROLE backup_user LOGIN PASSWORD '...';

-- PostgreSQL 14+: the built-in read-all role covers current and future tables.
GRANT pg_read_all_data TO backup_user;
```

On older servers, grant per database instead:

```sql
GRANT CONNECT ON DATABASE app_production TO backup_user;
GRANT USAGE ON SCHEMA public TO backup_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO backup_user;
```

Notes:

- `pg_dumpall --globals-only` (the `include_globals: true` option) reads
  `pg_authid` password hashes and therefore requires superuser on most
  servers. If you won't grant that, set `include_globals: false` and keep a
  role-recreation script in configuration management instead — but keep
  *something*: restoring to a fresh server without roles fails.
- Restores are a separate concern: run them as an owner/admin role, not as
  `backup_user`.

## Secrets

- **Never commit credentials.** The config is ERB-rendered, so every secret
  can come from the environment:
  `password: <%= ENV["PGKEEPER_APP_PASSWORD"] %>`.
- Alternatively set `pgpass: true` on a database and use a `~/.pgpass` /
  `PGPASSFILE` file (mode `0600`). PgKeeper then omits `PGPASSWORD` entirely.
- Credentials are passed to `pg_dump`/`psql` via libpq environment variables,
  never on the command line — they don't appear in `ps` output.
- `pgkeeper doctor` output, logs, manifests, and notification payloads never
  include credential values.

## Encryption at rest

Enable encryption **before** pointing storage at any third-party cloud:

```yaml
encryption:
  enabled: true
  type: aes256gcm            # built in (OpenSSL), or `gpg`
  passphrase_env: PGKEEPER_ENCRYPTION_PASSPHRASE
```

- AES-256-GCM is authenticated: tampered artifacts fail loudly on decrypt.
- The manifest records the encryption type; `restore`/`verify` reverse it
  transparently.
- Store the passphrase/keyfile somewhere that survives losing the backup host
  (a password manager, a KMS) — an encrypted backup whose key lived only on
  the dead server is not a backup.

### Rotating the encryption key

Changing `passphrase_env`/`keyfile` alone would strand every backup written
under the old key — nothing could decrypt them. Rotate through a keyring
instead: set the new key as the primary and keep the retired one(s) listed so
old backups stay restorable and verifiable.

```yaml
encryption:
  enabled: true
  type: aes256gcm
  passphrase_env: PGKEEPER_ENCRYPTION_PASSPHRASE          # the NEW key
  previous_passphrase_envs:
    - PGKEEPER_ENCRYPTION_PASSPHRASE_2025                 # the retired key
  # previous_keyfiles:
  #   - /etc/pgkeeper/keys/2025.key
```

New backups encrypt under the primary key; `restore`/`verify` try each key in
turn. Once every backup encrypted under a retired key has aged out of your
retention window, drop it from the list. Keep the retired secrets available for
at least as long as any backup that used them.

## Immutable backups (S3 Object Lock)

Retention safety rails guard against *PgKeeper's own* pruning deleting the wrong
thing. They do nothing against a leaked S3 credential or a compromised host that
deletes every object directly — the classic ransomware failure mode. On an
S3-family destination whose bucket was created with **Object Lock enabled**, add
a retention window so each uploaded backup is immutable (write-once, read-many)
until it expires:

```yaml
storage:
  - type: s3
    bucket: my-pgkeeper-backups
    object_lock:
      mode: COMPLIANCE       # GOVERNANCE (privileged bypass) | COMPLIANCE (no bypass)
      retain_days: 35        # keep >= your retention window
```

- **COMPLIANCE** cannot be shortened or removed by anyone (including the root
  account) until the object expires; **GOVERNANCE** can be bypassed by a caller
  holding `s3:BypassGovernanceRetention`.
- Object Lock must be turned on when the bucket is created — it can't be added
  later. PgKeeper only sets per-object retention on upload.
- Set `retain_days` at least as long as your retention policy keeps backups, or
  `prune` will try (and, under COMPLIANCE, fail) to delete still-locked objects.

## Artifacts on disk

- The local storage adapter writes artifacts with mode `0600` and finalizes
  atomically (temp file + rename + fsync).
- The run-history SQLite file and lock file live in `workdir`; keep the
  directory owned by the user PgKeeper runs as, mode `0700` recommended.
- Retention (`pgkeeper prune`) is the only thing that deletes backups, and it
  never deletes the newest or last-verified set.

## Web dashboard

The dashboard (`pgkeeper web`) is designed to be safe to run, but it still
exposes backup metadata and management actions — treat it like any admin UI:

- **Auth is mandatory.** It refuses to start without `web.auth.token`, a
  `web.auth.tokens` map, or `web.auth.username`+`password`. Credentials are
  compared in constant time. Give a token to browsers as the password of HTTP
  basic auth, or to scripts as `Authorization: Bearer <token>`.
- **One token per caller.** Prefer `web.auth.tokens` (name => secret) over a
  single shared token: each caller gets its own, revoked independently by
  deleting its entry and restarting, and the caller's name is logged with every
  action it triggers — so the log answers "who ran this". See
  [REMOTE-API.md](REMOTE-API.md).
- **Loopback by default.** It binds `127.0.0.1`; for remote access put it
  behind a TLS-terminating reverse proxy rather than binding `0.0.0.0` on the
  open internet. Basic auth (and a Bearer token) without TLS sends the
  credential in cleartext.
- **CSRF-protected.** Every browser management POST requires a CSRF token plus
  an explicit confirmation, and runs through the same lock as scheduled runs.
  (One deliberate exception to the confirmation — not the CSRF token: the
  Connections page's read-only "test connection" probe, which starts nothing
  and writes nothing.)
  The token-authenticated action API skips those browser-only guards because a
  Bearer header can't ride along on a cross-site request in the first place.
- **Downloads are allowlisted.** The download endpoint only serves paths the
  destination's catalog knows about — it cannot be steered at arbitrary files.
- **Config writes are browser-only and probe-gated.** The one config-mutating
  flow (adding a database from the Connections page) requires the CSRF token
  plus confirmation, is deliberately absent from the Bearer-token API (a
  leaked API token can trigger backups, not rewrite where they point), tests
  the connection before writing, and never persists the submitted password —
  the file gets an `<%= ENV["PGKEEPER_<NAME>_PASSWORD"] %>` reference, the
  same secrets-in-the-environment rule the wizard follows. The updated file is
  re-validated as a whole before it replaces the old one (atomic rename).
- **No restores.** Restore-from-browser is deliberately not implemented; a
  restore is too destructive for a web click. Use the CLI runbook
  ([RESTORE.md](RESTORE.md)).

## Reporting a vulnerability

Open a GitHub security advisory (preferred) or a private report to the
maintainers. Please do not open public issues for exploitable problems.
