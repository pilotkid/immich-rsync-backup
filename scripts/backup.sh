#!/usr/bin/env bash
set -euo pipefail
source /usr/local/bin/rsync-common.sh

# This lock is shared only within a running container. Do not run multiple replicas.
exec 9>/tmp/immich-rsync.lock
flock -n 9 || die 'Another backup is already running in this container.'

root="${MEDIA_ROOT:-/data}"
[[ -d "$root" ]] || die "Media root not mounted: $root"

[[ "${DB_BACKUP_MAX_AGE_HOURS:-48}" =~ ^[0-9]+$ ]] || die 'DB_BACKUP_MAX_AGE_HOURS must be an integer.'
if [[ "${TRIGGER_DB_BACKUP:-false}" == true ]]; then
  [[ "${REQUIRE_DB_BACKUP:-true}" == true ]] || die 'TRIGGER_DB_BACKUP=true requires REQUIRE_DB_BACKUP=true.'
  api_url="${IMMICH_API_URL:-}"
  api_key="${IMMICH_API_KEY:-}"
  api_key_file="${IMMICH_API_KEY_FILE:-}"
  [[ -n "$api_url" ]] || die 'Set IMMICH_API_URL when TRIGGER_DB_BACKUP=true.'
  [[ -n "$api_key" || -n "$api_key_file" ]] || die 'Set IMMICH_API_KEY or IMMICH_API_KEY_FILE when TRIGGER_DB_BACKUP=true.'
  [[ -z "$api_key" || -z "$api_key_file" ]] || die 'Set only one of IMMICH_API_KEY or IMMICH_API_KEY_FILE.'
  if [[ -n "$api_key_file" ]]; then
    [[ -r "$api_key_file" ]] || die "Immich API key file is not readable: $api_key_file"
    api_key="$(<"$api_key_file")"
  fi
  [[ "${DB_BACKUP_TRIGGER_TIMEOUT_SECONDS:-1800}" =~ ^[0-9]+$ && "${DB_BACKUP_TRIGGER_TIMEOUT_SECONDS:-1800}" -gt 0 ]] || die 'DB_BACKUP_TRIGGER_TIMEOUT_SECONDS must be a positive integer.'
  [[ -n "$api_key" ]] || die 'Immich API key is empty.'
  [[ -d "$root/backups" ]] || die "Immich database dumps directory missing: $root/backups"

  api_header_file="$(mktemp /tmp/immich-api-header.XXXXXX)"
  chmod 600 "$api_header_file"
  printf 'x-api-key: %s\n' "$api_key" > "$api_header_file"
  unset api_key
  started_at="$(date +%s)"
  api_url="${api_url%/}"
  log 'Requesting an Immich database dump.'
  if ! curl --fail --silent --show-error \
    --request POST \
    --header "@$api_header_file" \
    --header 'Content-Type: application/json' \
    --data '{"name":"backup-database"}' \
    "${api_url}/jobs" >/dev/null; then
    rm -f "$api_header_file"
    die 'Immich rejected the database dump request.'
  fi
  rm -f "$api_header_file"

  timeout_seconds="${DB_BACKUP_TRIGGER_TIMEOUT_SECONDS:-1800}"
  deadline=$((started_at + timeout_seconds))
  previous_file=''
  previous_size=''
  stable_count=0
  while (( $(date +%s) <= deadline )); do
    current_file=''
    current_size=''
    while IFS= read -r -d '' candidate; do
      modified="$(stat -c '%Y' "$candidate")"
      if (( modified >= started_at )); then
        current_file="$candidate"
        current_size="$(stat -c '%s' "$candidate")"
        break
      fi
    done < <(find "$root/backups" -type f -print0)

    if [[ -n "$current_file" && "$current_size" -gt 0 ]]; then
      if [[ "$current_file" == "$previous_file" && "$current_size" == "$previous_size" ]]; then
        ((stable_count += 1))
      else
        stable_count=0
      fi
      if (( stable_count >= 3 )); then
        log "Immich database dump is ready: ${current_file##*/}"
        break
      fi
      previous_file="$current_file"
      previous_size="$current_size"
    fi
    sleep 10
  done
  (( stable_count >= 3 )) || die "No completed Immich database dump appeared within ${timeout_seconds} seconds."
fi

if [[ "${REQUIRE_DB_BACKUP:-true}" == true ]]; then
  [[ -d "$root/backups" ]] || die "Immich database dumps directory missing: $root/backups"
  age_minutes=$((DB_BACKUP_MAX_AGE_HOURS * 60))
  if ! find "$root/backups" -type f -mmin "-$age_minutes" -print -quit | grep -q .; then
    die "No database dump newer than ${DB_BACKUP_MAX_AGE_HOURS} hours. Enable Immich's scheduled database dumps."
  fi
fi

setup_rsync

read -r -a dirs <<< "${SOURCE_DIRS:-upload library profile backups}"
[[ ${#dirs[@]} -gt 0 ]] || die 'SOURCE_DIRS is empty.'

sources=()
for dir in "${dirs[@]}"; do
  # Only paths relative to /data. No traversal outside the read-only mount.
  [[ "$dir" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ]] || die "Invalid source folder: $dir"
  [[ "$dir" != /* && "$dir" != *../* && "$dir" != '..' ]] || die "Unsafe source folder: $dir"
  if [[ -d "$root/$dir" ]]; then
    sources+=("$root/$dir")
  else
    log "Skipping missing source folder: $dir"
  fi
done
[[ ${#sources[@]} -gt 0 ]] || die "None of the configured source folders exist under $root."

log "Starting rsync backup (${#sources[@]} source folders, profile=${RSYNC_PROFILE:-standard}, mode=${BACKUP_MODE:-append})."
log "Destination: $RSYNC_DESTINATION"
# Trailing slash on destination makes the selected source directories children
# of the remote root (or remote module), not replacements for it.
rsync "${RSYNC_ARGS[@]}" "${sources[@]}" "${RSYNC_DESTINATION%/}/"
log 'Backup completed successfully.'
