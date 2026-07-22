# PgKeeper Storage Backends

Every backup run fans out to **all** configured destinations, and each is
tracked independently — one destination failing (a cloud outage) never stops the
others, and the run report shows per-destination status.

## Local filesystem

```yaml
storage:
  - type: local
    path: /var/backups/pgkeeper/backups
```

Artifacts are written `0600` via a temp-then-rename (atomic), with an fsync and a
free-space preflight.

## S3-compatible object storage

Works with **AWS S3** and any API-compatible service — **MinIO**, **Backblaze
B2**, **Cloudflare R2**, **DigitalOcean Spaces** — by pointing `endpoint` at the
provider.

Requires the optional `aws-sdk-s3` gem (`gem install aws-sdk-s3`, or add it to
your bundle). PgKeeper lazy-loads it, so a local-only install stays lean.

```yaml
storage:
  - type: s3
    bucket: my-pgkeeper-backups
    region: us-east-1
    prefix: production            # optional key prefix
    access_key_id: <%= ENV["AWS_ACCESS_KEY_ID"] %>
    secret_access_key: <%= ENV["AWS_SECRET_ACCESS_KEY"] %>
```

Credentials also resolve from the standard AWS chain (env, shared config,
instance/task role) if you omit `access_key_id`/`secret_access_key`.

### Non-AWS endpoints

```yaml
  - type: s3
    bucket: pgkeeper
    endpoint: https://s3.us-west-000.backblazeb2.com   # or your MinIO/R2 URL
    force_path_style: true        # required by MinIO and some S3-compatibles
    access_key_id: <%= ENV["S3_KEY"] %>
    secret_access_key: <%= ENV["S3_SECRET"] %>
```

### Least-privilege bucket policy (AWS)

The credentials need only object-level access to the prefix, plus a bucket
existence check:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::my-pgkeeper-backups" },
    { "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-pgkeeper-backups/*" }
  ]
}
```

`pgkeeper doctor` calls `HeadBucket` to confirm the bucket is reachable with the
given credentials before you rely on it.

## Verifying a destination

```sh
pgkeeper doctor -c pgkeeper.yml     # health-checks every configured destination
pgkeeper list   -c pgkeeper.yml     # what's stored, with verification status
```

## Roadmap

Google Drive, Dropbox, and SharePoint/OneDrive backends are planned. The storage
interface (`upload` / `download` / `list` / `delete` / `healthcheck` with retry +
backoff) is shared and contract-tested, so adding a provider is additive — see
`lib/pgkeeper/storage/`.
