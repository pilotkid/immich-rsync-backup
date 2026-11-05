#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/src/"{upload,library,profile,backups} "$tmp/remote"
printf 'photo-v1' > "$tmp/src/library/image.jpg"
printf 'database' > "$tmp/src/backups/dump.sql"
# Script expects the helpers at installed container path; stage them in a temp root
# by rewriting the one absolute import path for local test execution.
sed "s|source /usr/local/bin/rsync-common.sh|source \"$here/scripts/rsync-common.sh\"|" "$here/scripts/backup.sh" > "$tmp/backup.sh"
runbackup() {
  RSYNC_DESTINATION="$tmp/remote" \
  MEDIA_ROOT="$tmp/src" \
  RSYNC_PROFILE=standard \
  BACKUP_MODE=append \
  REQUIRE_DB_BACKUP=true \
  DB_BACKUP_MAX_AGE_HOURS=48 \
  bash "$tmp/backup.sh" >/dev/null
}
runbackup
[[ "$(cat "$tmp/remote/library/image.jpg")" == photo-v1 ]]
printf 'photo-v2' > "$tmp/src/library/image.jpg"
printf 'new' > "$tmp/src/upload/new.jpg"
runbackup
[[ "$(cat "$tmp/remote/library/image.jpg")" == photo-v1 ]]
[[ "$(cat "$tmp/remote/upload/new.jpg")" == new ]]
rm "$tmp/src/upload/new.jpg"
runbackup
[[ "$(cat "$tmp/remote/upload/new.jpg")" == new ]]
echo '--delete' > "$tmp/danger.txt"
if RSYNC_DESTINATION="$tmp/remote" RSYNC_OPTIONS_FILE="$tmp/danger.txt" RSYNC_PROFILE=custom MEDIA_ROOT="$tmp/src" REQUIRE_DB_BACKUP=false bash "$tmp/backup.sh" >/dev/null 2>&1; then
  echo 'Destructive rsync option unexpectedly accepted' >&2
  exit 1
fi
echo 'All local tests passed.'
