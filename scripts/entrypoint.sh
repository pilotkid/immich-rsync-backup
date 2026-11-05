#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

case "${1:-schedule}" in
  run|once)
    exec /usr/local/bin/backup.sh
    ;;
  check)
    [[ -d "${MEDIA_ROOT:-/data}" ]] || { log 'Media volume not mounted.'; exit 1; }
    source /usr/local/bin/rsync-common.sh
    setup_rsync
    log 'Configuration valid. This check does not contact the remote server.'
    ;;
  test-remote)
    source /usr/local/bin/rsync-common.sh
    setup_rsync
    filename="immich-rsync-test-$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"
    printf 'Immich rsync backup connectivity test: %s\n' "$(date -u -Is)" > "/tmp/$filename"
    log "Uploading temporary test object $filename"
    rsync "${RSYNC_ARGS[@]}" "/tmp/$filename" "${RSYNC_DESTINATION%/}/"
    log 'Transfer command succeeded; verify the uploaded object and test a restore.'
    ;;
  schedule)
    export TZ="${TZ:-UTC}"
    time="${BACKUP_TIME:-03:00}"
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { log 'BACKUP_TIME must be HH:MM in 24-hour time.'; exit 1; }
    log "Scheduling backups daily at $time ($TZ)."
    if [[ "${RUN_ON_START:-false}" == true ]]; then
      log 'RUN_ON_START enabled; executing immediately.'
      /usr/local/bin/backup.sh || log 'Initial backup failed (container will keep scheduling).'
    fi
    last_day=''
    while :; do
      today="$(date +%Y-%m-%d)"
      now="$(date +%H:%M)"
      if [[ "$now" == "$time" && "$last_day" != "$today" ]]; then
        last_day="$today"
        log 'Scheduled backup starting.'
        /usr/local/bin/backup.sh || log 'Scheduled backup FAILED; inspect logs.'
      fi
      sleep 20
    done
    ;;
  *)
    echo 'Usage: container [schedule|once|check|test-remote]' >&2
    exit 2
    ;;
esac
