# Storage Provider Setup

PgKeeper fans every backup out to all configured `storage:` targets. This
guide walks through credentials and configuration per provider.

Two backends ship today: **local filesystem** and **S3-compatible object
storage** (which covers AWS S3, MinIO, Backblaze B2, Cloudflare R2, and
DigitalOcean Spaces). The storage layer is a small adapter interface
(`lib/pgkeeper/storage/base.rb`), so further providers are additive.

Whatever the provider: run `pgkeeper doctor` afterwards — it health-checks
every configured destination with a harmless API call and tells you exactly
which one is misconfigured.

## Local filesystem

```yaml
storage:
  - type: local
    path: /var/backups/pgkeeper/backups
```

- Artifacts are written `0600`, staged and renamed atomically, fsynced.
- Free-space is checked before each run.
- Point `path` at a mount that is **not** the database's own disk — a dead
  disk taking both the database and its backups is the classic self-own.

## S3-compatible object storage

Requires the optional SDK once per host: `gem install aws-sdk-s3`
(already present in the Docker image).

```yaml
storage:
  - type: s3
    bucket: my-pgkeeper-backups
    region: us-east-1
    prefix: production            # optional key prefix
    access_key_id: <%= ENV["AWS_ACCESS_KEY_ID"] %>
    secret_access_key: <%= ENV["AWS_SECRET_ACCESS_KEY"] %>
```

Credentials can also come from the standard AWS chain (env vars, shared
credentials file, instance profile / IRSA) — omit the two key fields and the
SDK resolves them.

### AWS S3

1. Create a bucket (enable versioning if you want belt-and-braces protection
   against accidental deletion; PgKeeper's retention deletes objects).
2. Create an IAM user or role with a policy scoped to that bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-pgkeeper-backups/*" },
    { "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::my-pgkeeper-backups" }
  ]
}
```

3. Export the access key pair (or attach the role) and run `pgkeeper doctor`.

### MinIO / self-hosted S3

```yaml
  - type: s3
    bucket: pgkeeper
    region: us-east-1              # arbitrary but required by the SDK
    endpoint: https://minio.internal:9000
    force_path_style: true         # MinIO needs path-style addressing
    access_key_id: <%= ENV["MINIO_ACCESS_KEY"] %>
    secret_access_key: <%= ENV["MINIO_SECRET_KEY"] %>
```

### Backblaze B2

Create an application key scoped to one bucket, then:

```yaml
  - type: s3
    bucket: my-pgkeeper-backups
    region: us-west-000
    endpoint: https://s3.us-west-000.backblazeb2.com
    access_key_id: <%= ENV["B2_KEY_ID"] %>
    secret_access_key: <%= ENV["B2_APP_KEY"] %>
```

### Cloudflare R2

```yaml
  - type: s3
    bucket: my-pgkeeper-backups
    region: auto
    endpoint: https://<account-id>.r2.cloudflarestorage.com
    access_key_id: <%= ENV["R2_ACCESS_KEY_ID"] %>
    secret_access_key: <%= ENV["R2_SECRET_ACCESS_KEY"] %>
```

### DigitalOcean Spaces

```yaml
  - type: s3
    bucket: my-pgkeeper-backups
    region: nyc3
    endpoint: https://nyc3.digitaloceanspaces.com
    access_key_id: <%= ENV["SPACES_KEY"] %>
    secret_access_key: <%= ENV["SPACES_SECRET"] %>
```

## Multiple destinations & retention

Destinations are independent: one being down fails only that destination
(the run reports `partial`), and retention is enforced per destination — you
can keep 7 days locally and 30 in the cloud by running `pgkeeper prune`
with different configs, or simply let one policy apply everywhere.

Before anything ships to a third-party provider, read the encryption section
of [SECURITY.md](SECURITY.md).

## Google Drive / Dropbox / SharePoint

Not yet implemented. The original plan (PLAN.md Phase 4) sketches them; the
adapter interface (`upload` / `download` / `list` / `delete` / `healthcheck`)
plus the shared contract test suite (`test/support/storage_contract.rb`) is
the template — a new provider is one adapter class and one contract test
include. Contributions welcome.
