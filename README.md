# Immich rsync Backup Sidecar

A small, **provider-agnostic** Docker image for backing up Immich's original media and built-in PostgreSQL database dumps to any **real rsync endpoint**. Runs beside an existing Immich Docker Compose stack, including Docker Desktop on Windows.

- Source media mounted **read-only**; does not mount live PostgreSQL data.
- Scheduled daily uploads, with an optional immediate run.
- Two rsync profiles: `standard` and `custom`.
- Works with rsync-over-SSH (SSH key or a mounted password file), rsync daemon/module, or local filesystem destinations.
- No automatic remote deletion; destructive rsync flags are explicitly rejected.
- `append` mode never overwrites existing remote files on standard rsync servers.
- Secrets are **mounted at runtime**, never baked into the image.
- Builds locally or publishes to GHCR via the included GitHub Actions workflow.

> **Important:** An SFTP connection configured in rclone is *not* the same thing as an rsync connection. You must configure `RSYNC_DESTINATION` separately, even if `rclone lsd myremote:` works. Not all SFTP-only servers support rsync.

## 1. Build the image

From this repository:

```powershell
docker build -t immich-rsync-backup:local .
```

Or push this repository to GitHub (branch `main`) and GitHub Actions will publish `ghcr.io/YOUR_USER/YOUR_REPO:latest`. Change `BACKUP_IMAGE` in your Immich `.env` to use it. Set the GHCR image visibility and credentials as needed for your deployment.

## 2. Configure your Immich stack

Immich should already have `UPLOAD_LOCATION` configured in its `.env`. For example, on Windows:

```ini
UPLOAD_LOCATION=D:/Immich/photos
```

Copy `compose.sidecar.yml` alongside Immich's existing `docker-compose.yml`. You can merge its service definition under `services:` **or** use an override file:

```powershell
docker compose -f docker-compose.yml -f compose.sidecar.yml config
```

Add the relevant settings from `.env.example` to your existing Compose `.env`. Create these two folders alongside the existing compose file:

```powershell
New-Item -ItemType Directory -Force .\backup-config, .\backup-secrets
```

**Never** include populated `.env`, `backup-config`, or `backup-secrets` in the published Git repo or container image.

## 3. Choose a destination

### A. Amazon EC2 over rsync/SSH (Virginia example)

```ini
RSYNC_DESTINATION=ec2-user@ec2-YOUR_INSTANCE.compute-1.amazonaws.com:/srv/backups/immich
RSYNC_PROFILE=standard
BACKUP_MODE=append
```

Use an EC2 instance in `us-east-1` (N. Virginia) with rsync installed and the remote destination folder created and writable. Replace the placeholder with the instance's current public DNS name. Allow inbound SSH only from the backup host's public IP. Put the EC2 host key in `backup-config/known_hosts` after verifying its fingerprint. For key-based authentication, put your private key at `backup-config/id_ed25519`, then set `SSH_IDENTITY_FILE=/config/id_ed25519` in `.env`. Use the login name for your AMI (commonly `ec2-user` on Amazon Linux or `ubuntu` on Ubuntu). Do not put the private key in the image or repository. For password-based authentication, put the password in `backup-secrets/password` and set:

```ini
RSYNC_SSH_PASSWORD_FILE=/run/rsync-secrets/password
```

To collect a host-key candidate from PowerShell, use `ssh-keyscan` if available, **but independently verify the fingerprint with your provider** before trusting or adding it to `known_hosts`. Unknown SSH hosts are rejected by default.

### B. EC2 rsync daemon

```ini
RSYNC_DESTINATION=rsync://ec2-user@ec2-YOUR_INSTANCE.compute-1.amazonaws.com/module/immich
RSYNC_PROFILE=standard
BACKUP_MODE=append
RSYNC_DAEMON_PASSWORD_FILE=/run/rsync-secrets/password
```

This option assumes an rsync daemon is installed and configured on the EC2 instance and its security group allows the daemon's port. If the daemon requires a password, place it in `backup-secrets/password`. **Plain rsync daemon connections are not encrypted**: use a trusted network, tunnel, VPN or TLS-capable setup.

Amazon S3 buckets do not provide an rsync endpoint. These AWS examples use an EC2 server; configure separate storage or replication if you also need the files copied from that server into S3.

### C. Custom rsync endpoint / options

For any endpoint that accepts standard rsync arguments, use `RSYNC_PROFILE=custom` and optionally mount a file of additional arguments with `RSYNC_OPTIONS_FILE=/config/rsync-options.txt`. The file contains **one literal rsync argument per line** (no shell expansion), for example:

```text
--ignore-existing
--whole-file
```

The sidecar always includes `-r -v`. It blocks `--delete*`, `--del`, `--remove-source-files`, and other destructive flags. You can pass a custom `RSYNC_RSH` if SSH command needs differ from the built-in key/password options. Unsupported provider-specific rsync implementations may still need their own profile or modifications.

### Full Immich Compose example for Amazon EC2

[`examples/rsync/docker-compose.yml`](examples/rsync/docker-compose.yml) is a full Immich Compose stack based on the configuration provided for this project. It replaces the rclone backup service with `immich-rsync-backup`, configured to use an Amazon EC2 instance as an rsync-over-SSH destination. It uses `RSYNC_PROFILE=standard` and `BACKUP_MODE=append`; an S3 bucket itself is not an rsync endpoint. Set `RSYNC_DESTINATION` to your EC2 public DNS name and remote directory. Put the verified EC2 host key and private key in `examples/rsync/backup-config/known_hosts` and `examples/rsync/backup-config/id_ed25519`.

The full-stack example also sets `TRIGGER_DB_BACKUP=true`. Add an Immich administrator API key with job creation permission to `examples/rsync/backup-secrets/immich-api-key`. Follow [`examples/rsync/README.md`](examples/rsync/README.md) and edit [`examples/rsync/.env.example`](examples/rsync/.env.example) for all required values. Do not commit the populated `.env` or private key.

From the repository root, these commands prepare and start the example:

```bash
#Bash
cd examples/rsync
cp .env.example .env
mkdir -p backup-config backup-secrets
docker compose up -d --build
```

```powershell
#Powershell
Set-Location .\examples\rsync
Copy-Item .env.example .env
New-Item -ItemType Directory -Force .\backup-config, .\backup-secrets
docker compose up -d --build
```

## 4. Ensure Immich database dumps exist

In Immich, open **Administration → Settings → Database Dump Settings** and enable database dumps. Immich stores them in `UPLOAD_LOCATION/backups`; set retention there as desired. The sidecar defaults to a **3 AM** backup and refuses to run if no dump exists in that folder newer than 48 hours. A full Immich recovery requires the original media **and** its database. Live DB files under `DB_DATA_LOCATION` are not safely backed up by copying them from a running database.

### Automatically trigger a fresh Immich database dump

The sidecar can ask Immich to create a new dump before every scheduled or manual backup. The default is `TRIGGER_DB_BACKUP=false`, which only checks that a recent dump already exists.

1. In Immich, create an API key for an administrator account with permission to create jobs.
2. Make sure the sidecar and Immich server share a Docker network. With the provided full-stack example, use `IMMICH_API_URL=http://immich-server:2283/api`; for a split stack, use an API URL reachable from the sidecar container.
3. Save the API key in a file mounted into the sidecar. With the standard Compose override, create `backup-secrets/immich-api-key` and keep `IMMICH_API_KEY_FILE=/run/rsync-secrets/immich-api-key`. In the full-stack example this path and mount are already configured.
4. Set `TRIGGER_DB_BACKUP=true` and keep `REQUIRE_DB_BACKUP=true`. Set `DB_BACKUP_TRIGGER_TIMEOUT_SECONDS` high enough for the dump to complete; the default is 1800 seconds (30 minutes).
5. Recreate the sidecar container. Start with one manual run and inspect its logs before relying on the daily schedule.

For example, add these values to the Compose `.env`:

```ini
TRIGGER_DB_BACKUP=true
IMMICH_API_URL=http://immich-server:2283/api
IMMICH_API_KEY_FILE=/run/rsync-secrets/immich-api-key
DB_BACKUP_TRIGGER_TIMEOUT_SECONDS=1800
REQUIRE_DB_BACKUP=true
```

From the Immich Compose folder, run one backup and then start the scheduled service:

```bash
docker compose -f docker-compose.yml -f compose.sidecar.yml run --rm immich-rsync-backup once
docker compose -f docker-compose.yml -f compose.sidecar.yml up -d immich-rsync-backup
```

```powershell
docker compose -f docker-compose.yml -f compose.sidecar.yml run --rm immich-rsync-backup once
docker compose -f docker-compose.yml -f compose.sidecar.yml up -d immich-rsync-backup
```

Each run submits Immich's `backup-database` job, waits for a new dump file to stop changing, then starts rsync. If Immich rejects the request or a completed dump does not appear before the timeout, that run stops without uploading. This uses Immich's current `POST /api/jobs` endpoint and may need updating if Immich changes that API.

By default this transfers `upload`, `library`, `profile` and `backups` from the `UPLOAD_LOCATION` volume. It skips `thumbs` and `encoded-video` (regenerable) and **does not automatically include Immich external libraries**. To include external libraries, add a separate read-only mount and change `SOURCE_DIRS`/`MEDIA_ROOT`, or run an additional instance for those mounts.

## 5. Preflight, small remote test, and first backup

From the Immich Compose folder:

```powershell
# Validate Compose configuration
docker compose -f docker-compose.yml -f compose.sidecar.yml config

# Validate sidecar configuration (no connection attempt)
docker compose -f docker-compose.yml -f compose.sidecar.yml run --rm immich-rsync-backup check

# Upload one small test object using rsync (does not need a DB dump)
docker compose -f docker-compose.yml -f compose.sidecar.yml run --rm immich-rsync-backup test-remote

# First backup, manually started
docker compose -f docker-compose.yml -f compose.sidecar.yml run --rm immich-rsync-backup once

# Start scheduled sidecar
docker compose -f docker-compose.yml -f compose.sidecar.yml up -d immich-rsync-backup
```

A successful `test-remote` **leaves a small object** at the destination. Verify it exists and test an actual restore before relying on the backup. Never launch a multi-terabyte upload without a recovery test.

The default schedule is 03:00 in the container's `TZ`; change `BACKUP_TIME=HH:MM`. `RUN_ON_START=true` also triggers immediately when the sidecar starts. This scheduler checks local time every 20 seconds. If the container is stopped at the scheduled minute, that day's run may be missed; monitor the logs and consider an external scheduler for stricter guarantees.

## Environment variable reference

The following variables configure the backup container. Defaults shown are those used by `compose.sidecar.yml`; the full-stack example may set its own defaults for an EC2 SSH destination.

### Backup schedule and source

| Variable | Default | Description |
|---|---|---|
| `TZ` | `America/Denver` | Time zone used by the daily scheduler and log timestamps. Use a valid time zone name. |
| `BACKUP_TIME` | `03:00` | Daily start time in 24-hour `HH:MM` format. |
| `RUN_ON_START` | `false` | Also run a backup immediately when the scheduled sidecar starts. |
| `SOURCE_DIRS` | `upload library profile backups` | Whitespace-separated directories under `MEDIA_ROOT` to upload. Missing directories are skipped. |
| `MEDIA_ROOT` | `/data` | Container path containing the Immich upload folders. The Compose volume must mount the data at this path. |
| `REQUIRE_DB_BACKUP` | `true` | Require a recent file under `backups` before rsync. Must stay `true` when `TRIGGER_DB_BACKUP=true`. |
| `DB_BACKUP_MAX_AGE_HOURS` | `48` | Maximum age of an existing database dump when it is required. |

### Destination and rsync behavior

| Variable | Default | Description |
|---|---|---|
| `RSYNC_DESTINATION` | Required | Destination in rsync-over-SSH form (`user@host:/path`), daemon form (`rsync://host/module/path`), or local path. For AWS examples, use an EC2 host; an S3 bucket is not an rsync endpoint. |
| `RSYNC_PROFILE` | `standard` | `standard` selects the built-in append/update behavior. `custom` allows additional arguments through `RSYNC_OPTIONS_FILE`. |
| `BACKUP_MODE` | `append` | For `standard`: `append` skips files already at the destination; `update` sends timestamp comparison options and can overwrite changed files. |
| `DRY_RUN` | `false` | Pass rsync's dry-run option so it reports planned transfers without changing the remote files. If dump triggering is enabled, Immich still creates the dump. |
| `RSYNC_OPTIONS_FILE` | Empty | Optional mounted text file with one literal rsync argument per line. Destructive options are rejected. |
| `RSYNC_RSH` | Empty | Optional remote-shell command passed to rsync. When set, it overrides the sidecar's automatic SSH command construction. |

### SSH and rsync daemon authentication

| Variable | Default | Description |
|---|---|---|
| `SSH_PORT` | `22` | Port for rsync-over-SSH. |
| `SSH_IDENTITY_FILE` | Empty | Path inside the container to an SSH private key, typically `/config/id_ed25519`. SSH requires a verified `/config/known_hosts` file. |
| `RSYNC_SSH_PASSWORD_FILE` | Empty | Path inside the container to a file containing the SSH password. The password file is mounted read-only; `sshpass` uses it for SSH authentication. |
| `RSYNC_DAEMON_PASSWORD_FILE` | Empty | Path inside the container to a password file for an rsync daemon module. |

Store credentials in files under the mounted secrets/config directories instead of placing secret values directly in Compose environment variables.

### Immich database dump trigger

| Variable | Default | Description |
|---|---|---|
| `TRIGGER_DB_BACKUP` | `false` | Ask Immich to create a fresh database dump before each backup run. Requires `REQUIRE_DB_BACKUP=true`. |
| `IMMICH_API_URL` | Empty | Immich API base URL, including `/api`, such as `http://immich-server:2283/api`. Must be reachable from the sidecar. |
| `IMMICH_API_KEY_FILE` | Empty | Path inside the container to a file containing an Immich administrator API key with permission to create jobs. |
| `DB_BACKUP_TRIGGER_TIMEOUT_SECONDS` | `1800` | How long to wait for the triggered dump file to appear and stop changing. Must be a positive integer. |

### Compose-only variables

These values are used by Compose to select the image or mount host directories; they are not backup script settings:

| Variable | Default | Description |
|---|---|---|
| `BACKUP_IMAGE` | `immich-rsync-backup:local` | Container image to run. |
| `UPLOAD_LOCATION` | Required | Host path for Immich's upload directory, mounted read-only at `/data` by the supplied Compose service. |
| `BACKUP_CONFIG_DIR` | `./backup-config` | Host directory mounted read-only at `/config` for `known_hosts` and SSH keys. |
| `BACKUP_SECRETS_DIR` | `./backup-secrets` | Host directory mounted read-only at `/run/rsync-secrets` for API and password files. |

## Backup semantics and warnings

| Mode | Flags | Notes |
|---|---|---|
| `standard` + `append` (default) | `-r -v --ignore-existing` | Never overwrites remote files, never deletes. If a source file changes at the same path, the old remote version is retained and the new contents are **not** uploaded. A partially uploaded file that exists remotely may be skipped on retry; investigate and recover it. |
| `standard` + `update` | `-r -v -t` | Updates changed files but cannot preserve older versions of overwritten files; never deletes remote files. |
| `custom` | `-r -v` plus options file | Use when the remote needs other settings. |

This tool is **not an immutable, versioned backup**. Remote credentials can typically delete data; plan independent local backups and monitor runs. Remote rsync may be slow over many small files and on Windows bind mounts. A 3 TB first upload can take days. If an existing file is renamed, ordinary rsync treats it as a new object, so remote usage can grow substantially. AWS storage, data transfer, and recovery charges depend on the services you use.

## Restore overview

1. Request unsealing/restoration in the storage provider first if necessary.
2. Use reverse rsync to copy the saved `upload`, `library`, `profile`, and `backups` data into a newly provisioned Immich `UPLOAD_LOCATION` (do not `--delete` existing data unless you know exactly why).
3. Follow Immich's documented PostgreSQL database restore procedure for a compatible Immich release.
4. Verify media and metadata. Rebuild thumbnails/transcodes as needed.

Read the provider's restore process *before* you need it. This repository does not implement automatic restore.

## Testing locally

Run `bash tests/test-local.sh` from this repository. It tests append-mode rsync behavior using local directories and never connects to AWS or another remote provider.
