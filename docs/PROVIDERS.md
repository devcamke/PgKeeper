# Storage Provider Setup

PgKeeper fans every backup out to all configured `storage:` targets. This
guide walks through credentials and configuration per provider.

Five backends ship today: **local filesystem**, **S3-compatible object
storage** (which covers AWS S3, MinIO, Backblaze B2, Cloudflare R2, and
DigitalOcean Spaces), **Dropbox**, **Google Drive**, and **SharePoint /
OneDrive**. The storage layer is a small adapter interface
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

## Dropbox

No SDK required — the adapter talks to the Dropbox HTTP API v2 directly. Large
artifacts stream through an upload session, so dumps above Dropbox's 150 MB
single-request ceiling upload fine.

```yaml
storage:
  - type: dropbox
    root: /pgkeeper                                  # folder prefix; omit for the app root
    refresh_token: <%= ENV["DROPBOX_REFRESH_TOKEN"] %>
    app_key: <%= ENV["DROPBOX_APP_KEY"] %>
    app_secret: <%= ENV["DROPBOX_APP_SECRET"] %>
```

**Set up an app and a refresh token:**

1. At <https://www.dropbox.com/developers/apps>, create an app. **Scoped
   access** with the **App folder** access type keeps PgKeeper confined to its
   own folder (recommended); **Full Dropbox** works too.
2. On the app's **Permissions** tab, enable `files.content.write`,
   `files.content.read`, and `files.metadata.read`, then submit.
3. Note the **App key** and **App secret** from the Settings tab.
4. Mint a **refresh token** (it doesn't expire, and PgKeeper exchanges it for a
   short-lived access token per run):

   ```sh
   # 1. Open this in a browser, approve, copy the one-time code:
   #    https://www.dropbox.com/oauth2/authorize?client_id=APP_KEY&response_type=code&token_access_type=offline
   # 2. Exchange the code for a refresh token:
   curl https://api.dropboxapi.com/oauth2/token \
     -d code=THE_CODE -d grant_type=authorization_code \
     -u APP_KEY:APP_SECRET
   ```

   The JSON response's `refresh_token` is what goes in `DROPBOX_REFRESH_TOKEN`.
5. Run `pgkeeper doctor` — it calls `/2/check/user` to confirm the token works.

A long-lived `access_token` is also accepted in place of the refresh-token
triple, but Dropbox now issues short-lived tokens by default, so the refresh
flow above is the durable choice.

## Google Drive

No SDK required — the adapter talks to the Drive REST API v3 directly and signs
its own service-account JWT. Each backup is stored as a file whose name is the
full path (e.g. `db/app-2026.dump`) inside one folder you control; large
artifacts stream through a resumable upload session, so dumps above the simple
100 MB upload limit go through fine.

```yaml
storage:
  - type: google_drive
    folder_id: <%= ENV["GDRIVE_FOLDER_ID"] %>          # the folder's ID from its URL
    credentials_file: /etc/pgkeeper/service-account.json
    # or inline the key JSON from an env var instead of a file:
    # credentials_json: <%= ENV["GDRIVE_SERVICE_ACCOUNT_JSON"] %>
```

**Set up a service account and folder:**

1. In the [Google Cloud console](https://console.cloud.google.com/), create (or
   pick) a project and **enable the Google Drive API**.
2. Create a **service account**, then add a **JSON key** — download it; this is
   the `credentials_file` (it contains `client_email` and `private_key`).
3. In Google Drive, create the destination folder. **Share it with the service
   account's email** (the `client_email` from the key) and grant **Editor**.
   PgKeeper only ever touches this folder.
4. Copy the folder's ID from its URL
   (`https://drive.google.com/drive/folders/<FOLDER_ID>`) into `folder_id`.
5. Run `pgkeeper doctor` — it fetches the folder's metadata to confirm the
   credentials and access are good.

> Store the key JSON as a secret, not in the repo. Either point
> `credentials_file` at a file deployed out-of-band, or feed the whole JSON
> through `credentials_json` from an environment variable.

## SharePoint / OneDrive

No SDK required — the adapter uses the Microsoft Graph API with an app-only
(client-credentials) token. Backups land in one drive (a SharePoint document
library or a OneDrive) addressed by its `drive_id`; large artifacts stream
through a Graph upload session.

```yaml
storage:
  - type: sharepoint
    drive_id: <%= ENV["GRAPH_DRIVE_ID"] %>
    tenant_id: <%= ENV["AZURE_TENANT_ID"] %>
    client_id: <%= ENV["AZURE_CLIENT_ID"] %>
    client_secret: <%= ENV["AZURE_CLIENT_SECRET"] %>
    root: pgkeeper                 # optional folder prefix within the drive
```

**Register an app and find the drive:**

1. In **Entra ID → App registrations**, create an app. Under **Certificates &
   secrets**, add a **client secret** (that's `client_secret`). The app's
   **Application (client) ID** and the **Directory (tenant) ID** are
   `client_id` and `tenant_id`.
2. Under **API permissions**, add the **application** permission
   `Files.ReadWrite.All` (Microsoft Graph), then **grant admin consent**.
   App-only access needs an application permission, not a delegated one.
3. Find the target `drive_id` with the token from step 1–2:
   - **OneDrive:** `GET https://graph.microsoft.com/v1.0/users/{user-id}/drive`
   - **SharePoint:** resolve the site, then its default library —
     `GET /sites/{hostname}:/sites/{site-path}` then `GET /sites/{site-id}/drive`

   Use the returned `id` as `drive_id`.
4. Run `pgkeeper doctor` — it fetches the drive's root to confirm the app can
   reach it.

> The app can read and write **every** file in that drive with
> `Files.ReadWrite.All`, so dedicate a drive/library to backups and keep the
> client secret out of the repo (feed it from an environment variable).

## Adding another provider

The storage interface (`upload` / `download` / `list` / `delete` /
`healthcheck`, with shared retry + backoff) plus the contract test suite
(`test/support/storage_contract.rb`) is the template — a new provider is one
adapter class and one contract-test include, as the Dropbox, Google Drive, and
SharePoint adapters (`lib/pgkeeper/storage/`) all demonstrate. Contributions
welcome.
