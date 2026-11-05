# Full Immich Compose example

This example combines the Immich stack from the provided baseline with this repository's rsync backup sidecar. The sidecar replaces the baseline's rclone backup service and uses an Amazon EC2 instance as an rsync-over-SSH destination. It triggers a fresh Immich database dump before uploading the selected media folders and dump files.

## Prepare it

1. Check the Immich installation guide and download the current release's `docker-compose.yml` and matching hardware acceleration files if needed. Immich recommends using the compose file from the current release; the pinned Valkey and PostgreSQL images in this example come from the supplied baseline and may need updating with that release.
2. Copy `.env.example` to `.env`. Set absolute host paths and database credentials. Replace the sample EC2 host with your instance's current public DNS name and confirm the destination directory exists and is writable by the SSH user.
3. Ensure the external Docker network `proxy-network` exists. Create it with `docker network create proxy-network` if needed.
4. Create `backup-config` and `backup-secrets` beside this Compose file. Put the EC2 host key in `backup-config/known_hosts` after independently verifying its fingerprint. Put the EC2 private key in `backup-config/id_ed25519`; allow inbound SSH only from the backup host's public IP.
5. Put an Immich administrator API key with job creation permission in `backup-secrets/immich-api-key`.

Start the stack from this directory:

```bash
docker compose up -d --build
```

PowerShell equivalent, from this directory:

```powershell
docker compose up -d --build
```

The Immich API key and EC2 private key are mounted read-only into the sidecar. Do not commit `.env`, `backup-secrets`, or real key files. Amazon S3 buckets do not provide an rsync-over-SSH endpoint; this example uses EC2 as the rsync host. Verify a small backup and restore before relying on this for important data.
