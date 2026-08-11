#!/usr/bin/env bash
set -euo pipefail

PASSFILE=/root/.restic-password
LOCAL_REPO=/srv/docker-data/restic-repo
ARRAY_REPO=/srv/media/restic-mirror
set -a
  . /root/.restic-b2.env   # RESTIC_B2_REPO
set +a

latest_time() {
  restic -r "$1" --password-file "$PASSFILE" snapshots --tag nightly --latest 1 --json \
    | grep -o '"time":"[^"]*"' | cut -d'"' -f4 | sort -r | head -1
}

local_t=$(latest_time "$LOCAL_REPO")
array_t=$(latest_time "$ARRAY_REPO")
b2_t=$(latest_time "$RESTIC_B2_REPO")

printf 'local (sdb):        %s\n' "$local_t"
printf 'array mirror (md0): %s\n' "$array_t"
printf 'backblaze:          %s\n' "$b2_t"

if [ "$local_t" = "$array_t" ] && [ "$local_t" = "$b2_t" ]; then
  echo "IN SYNC — all three repos hold the identical nightly snapshot"
else
  echo "OUT OF SYNC — one or more legs are behind" >&2
  exit 1
fi
