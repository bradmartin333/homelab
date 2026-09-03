#!/usr/bin/env bash
set -euo pipefail

PASSFILE=/root/.restic-password
LOCAL_REPO=/srv/docker-data/restic-repo
ARRAY_REPO=/srv/media/restic-mirror
PI_ENV=/root/.restic-pi.env
set -a
  # shellcheck disable=SC1091
  . /root/.restic-b2.env   # RESTIC_B2_REPO
  # shellcheck source=/dev/null
  if [ -f "$PI_ENV" ]; then . "$PI_ENV"; fi   # PI_REPO, optional — see docs/pi-backup.md
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

# The Pi leg is a separate `restic backup` with a wider source set (it also
# covers Immich), not a `copy` of $LOCAL_REPO, so it never holds the exact
# same snapshot as the other three — reported alongside them, not held to the
# identical-snapshot bar below. scripts/pi-verify.sh is the real check for it.
if [ -n "${PI_REPO:-}" ]; then
  pi_t=$(latest_time "$PI_REPO")
  printf 'pi:                 %s\n' "${pi_t:-unreachable}"
fi

if [ "$local_t" = "$array_t" ] && [ "$local_t" = "$b2_t" ]; then
  echo "IN SYNC — local, array mirror, and B2 hold the identical nightly snapshot"
else
  echo "OUT OF SYNC — one or more legs are behind" >&2
  exit 1
fi
