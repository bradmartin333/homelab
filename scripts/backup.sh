#!/usr/bin/env bash
set -euo pipefail

LOCAL_REPO=/mnt/backup/restic-repo
PASSFILE=/root/.restic-password
STAGING=/var/lib/homelab-backup-staging
PGUSER=postgres

SOURCES=(
  "$STAGING"
  /opt/homelab
  /srv/docker-data/vikunja/files
)

mkdir -p "$STAGING"
chmod 700 "$STAGING"

# Dump to a temp file and move on success, so a failed dump can never
# replace last night's good one with a truncated file.
docker exec postgres pg_dumpall -U "$PGUSER" > "$STAGING/pg_dumpall.sql.tmp"
mv "$STAGING/pg_dumpall.sql.tmp" "$STAGING/pg_dumpall.sql"
docker exec immich-postgres pg_dumpall -U immich > "$STAGING/immich_pg_dumpall.sql.tmp"
mv "$STAGING/immich_pg_dumpall.sql.tmp" "$STAGING/immich_pg_dumpall.sql"

restic -r "$LOCAL_REPO" --password-file "$PASSFILE" backup --tag nightly "${SOURCES[@]}"
restic -r "$LOCAL_REPO" --password-file "$PASSFILE" forget --tag nightly \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
restic -r "$LOCAL_REPO" --password-file "$PASSFILE" check

# Dead man's switch — see the main doc's 19.3. Only reached if everything above succeeded.
curl -fsS -m 10 --retry 3 https://hc-ping.com/9923bec3-33a7-4813-83bf-00bd02be74f6 > /dev/null
