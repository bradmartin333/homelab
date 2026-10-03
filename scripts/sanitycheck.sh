#!/usr/bin/env bash
set -euo pipefail

PASSFILE=/root/.restic-password
LOCAL_REPO=/srv/docker-data/restic-repo
ARRAY_REPO=/srv/media/restic-mirror
PI_ENV=/root/.restic-pi.env
B2_ENV=/root/.restic-b2.env
# Every failure below says what failed. Under set -e a bare missing file or
# empty grep would otherwise exit 1 with no output at all.
[ -f "$B2_ENV" ] || { echo "error: $B2_ENV not found (run with sudo?)" >&2; exit 1; }
set -a
  # shellcheck source=/dev/null
  . "$B2_ENV"   # RESTIC_B2_REPO
  # shellcheck source=/dev/null
  if [ -f "$PI_ENV" ]; then . "$PI_ENV"; fi   # PI_REPO, optional — see docs/pi-backup.md
set +a

# Prints nothing for a repo with no nightly snapshots (restic prints `[]`);
# fails only if restic itself does.
latest_time() {
  local json
  json=$(restic -r "$1" --password-file "$PASSFILE" snapshots --tag nightly --latest 1 --json) || return 1
  { grep -o '"time":"[^"]*"' || true; } <<< "$json" | cut -d'"' -f4 | sort -r | head -1
}

local_t=$(latest_time "$LOCAL_REPO")    || { echo "error: can't read local repo $LOCAL_REPO" >&2; exit 1; }
array_t=$(latest_time "$ARRAY_REPO")    || { echo "error: can't read array mirror $ARRAY_REPO" >&2; exit 1; }
b2_t=$(latest_time "$RESTIC_B2_REPO")   || { echo "error: can't read B2 repo $RESTIC_B2_REPO" >&2; exit 1; }

printf 'local (sdb):        %s\n' "${local_t:-no nightly snapshots}"
printf 'array mirror (md0): %s\n' "${array_t:-no nightly snapshots}"
printf 'backblaze:          %s\n' "${b2_t:-no nightly snapshots}"

# The Pi leg is a separate `restic backup` with a wider source set (it also
# covers Immich), not a `copy` of $LOCAL_REPO, so it never holds the exact
# same snapshot as the other three — reported alongside them, not held to the
# identical-snapshot bar below. scripts/pi-verify.sh is the real check for it.
if [ -n "${PI_REPO:-}" ]; then
  pi_t=$(latest_time "$PI_REPO" 2>/dev/null || true)
  printf 'pi:                 %s\n' "${pi_t:-unreachable}"
fi

if [ -z "$local_t" ] || [ -z "$array_t" ] || [ -z "$b2_t" ]; then
  echo "OUT OF SYNC — at least one leg has no nightly snapshots" >&2
  exit 1
elif [ "$local_t" = "$array_t" ] && [ "$local_t" = "$b2_t" ]; then
  echo "IN SYNC — local, array mirror, and B2 hold the identical nightly snapshot"
else
  echo "OUT OF SYNC — one or more legs are behind" >&2
  exit 1
fi
