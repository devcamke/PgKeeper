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

Large artifacts upload via **multipart** (parallel parts, each retried
independently); files below 100 MiB go in a single request. This streams the
file part-by-part — memory stays flat — and lifts the 5 GiB ceiling that a
single `PutObject` would impose, so multi-gigabyte dumps upload cleanly.

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
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::my-pgkeeper-backups/*" }
  ]
}
```

`pgkeeper doctor` calls `HeadBucket` to confirm the bucket is reachable with the
given credentials before you rely on it.

## Dropbox

Needs no gem — the adapter uses the Dropbox HTTP API v2 directly. Large
artifacts stream through an upload session, lifting the 150 MB single-request
ceiling so multi-gigabyte dumps upload cleanly.

```yaml
storage:
  - type: dropbox
    root: /pgkeeper                                  # folder prefix; omit for the app root
    refresh_token: <%= ENV["DROPBOX_REFRESH_TOKEN"] %>
    app_key: <%= ENV["DROPBOX_APP_KEY"] %>
    app_secret: <%= ENV["DROPBOX_APP_SECRET"] %>
```

A long-lived `access_token` is accepted in place of the refresh-token triple.
See [PROVIDERS.md](PROVIDERS.md#dropbox) for creating the app and minting a
refresh token. `pgkeeper doctor` calls `/2/check/user` to confirm the token
works.

## Google Drive

Needs no gem — the adapter uses the Drive REST API v3 and signs its own
service-account JWT. Backups land in one folder you share with the service
account; large files stream through a resumable upload session.

```yaml
storage:
  - type: google_drive
    folder_id: <%= ENV["GDRIVE_FOLDER_ID"] %>
    credentials_file: /etc/pgkeeper/service-account.json
    # credentials_json: <%= ENV["GDRIVE_SERVICE_ACCOUNT_JSON"] %>   # inline alternative
```

See [PROVIDERS.md](PROVIDERS.md#google-drive) for creating the service account,
enabling the Drive API, and sharing the folder. `pgkeeper doctor` fetches the
folder's metadata to confirm access.

## SharePoint / OneDrive

Needs no gem — the adapter uses the Microsoft Graph API with an app-only token.
Backups land in one drive (`drive_id`); large files stream through a Graph
upload session.

```yaml
storage:
  - type: sharepoint
    drive_id: <%= ENV["GRAPH_DRIVE_ID"] %>
    tenant_id: <%= ENV["AZURE_TENANT_ID"] %>
    client_id: <%= ENV["AZURE_CLIENT_ID"] %>
    client_secret: <%= ENV["AZURE_CLIENT_SECRET"] %>
    root: pgkeeper                 # optional folder prefix within the drive
```

See [PROVIDERS.md](PROVIDERS.md#sharepoint--onedrive) for registering the app
(needs the `Files.ReadWrite.All` application permission with admin consent) and
finding the `drive_id`. `pgkeeper doctor` fetches the drive root to confirm
access.

## Verifying a destination

```sh
pgkeeper doctor -c pgkeeper.yml     # health-checks every configured destination
pgkeeper list   -c pgkeeper.yml     # what's stored, with verification status
```

## Adding a provider

The storage interface (`upload` / `download` / `list` / `delete` /
`healthcheck` with retry + backoff) is shared and contract-tested, so adding a
provider is additive — the Dropbox, Google Drive, and SharePoint adapters
(`lib/pgkeeper/storage/`) are worked examples.
