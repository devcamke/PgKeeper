# PgKeeper Security Guide

Backups are a high-value target: a single artifact contains your whole database.
Treat them accordingly.

## A least-privilege backup role

`pg_dump` doesn't need superuser — it needs to *read* everything you back up.
Create a dedicated role rather than backing up as `postgres`:

```sql
CREATE ROLE backup_user LOGIN PASSWORD 'set-via-secret-manager';

-- Let it connect and read the target database:
GRANT CONNECT ON DATABASE app_production TO backup_user;
\c app_production
GRANT USAGE ON SCHEMA public TO backup_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO backup_user;
```

Notes:
- **Globals / `include_globals`:** dumping roles and tablespaces with
  `pg_dumpall --globals-only` requires a role that can read `pg_authid`
  (superuser, or `pg_read_all_settings`/membership that exposes it). If you don't
  grant that, drop `include_globals` and manage roles separately.
- **Restores** need more privilege than backups (creating objects, owners). Use a
  separate, more-privileged role for `pgkeeper restore`, not the backup role.
- On PostgreSQL 15+, `pg_read_all_data` is a convenient predefined role that
  grants read on all tables/sequences without per-table grants.

## Secrets never live in the config file

The config is committed-safe: passwords come from the environment via ERB.

```yaml
password: <%= ENV["PGKEEPER_APP_PASSWORD"] %>
```

- Prefer a secret manager / orchestrator secrets (Kubernetes, systemd
  `LoadCredential`, Docker secrets) over plain env vars where you can.
- `.pgpass` is supported: set `pgpass: true` on a database and PgKeeper won't put
  a password in the process environment or argv.
- The example `.gitignore` excludes `pgkeeper.yml`, dumps, and `history.sqlite3`.

## Encryption before the cloud

Anything leaving your own disk should be encrypted at rest. Enable it *before*
adding cloud destinations:

```yaml
encryption:
  enabled: true
  type: aes256gcm
  passphrase_env: PGKEEPER_ENCRYPTION_PASSPHRASE
```

- AES-256-GCM is authenticated: tampering is detected on decrypt.
- **Store the passphrase/keyfile separately from the backups.** A backup you
  can't decrypt is not a backup — but a passphrase stored next to the ciphertext
  defeats the purpose.

## Artifact & transport hygiene

- Local artifacts are written `0600` (owner-only) via a temp-then-rename.
- Cloud uploads use TLS and verify the stored size after upload.
- Restrict who can read the backup destination (bucket policy, directory perms).
- `pgkeeper doctor` health-checks each destination (e.g. S3 `HeadBucket`) so
  broken or over-broad credentials surface early.

## Reporting

Found a security issue? Please report it privately via the repository's security
advisory / contact channel rather than a public issue.
