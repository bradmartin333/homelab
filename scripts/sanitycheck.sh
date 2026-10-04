#!/usr/bin/env bash
set -euo pipefail

PASSFILE=/root/.restic-password
LOCAL_REPO=/srv/docker-data/restic-repo
ARRAY_REPO=/srv/media/restic-mirror
PI_ENV=/root/.restic-pi.env
B2_ENV=/root/.restic-b2.env
GICKUP_CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gickup/conf.yml"
MIRROR_DIR=/srv/docker-data/gickup/github.com/bradmartin333
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

# Repo names under `include:` in gickup's conf.yml, one per line. A copy of
# the same function in healthcheck.sh; see the note there.
gickup_include() {
  awk '/^[[:space:]]*include:/ { f = 1; next }
       f && /^[[:space:]]*#/  { next }
       f && /^[[:space:]]*- / { sub(/^[[:space:]]*- */, ""); print; next }
       f                      { f = 0 }' "$1"
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

# Each whitelisted GitHub mirror should be in the latest nightly snapshot.
# Only the local repo is listed: the sync check below holds the array mirror
# and B2 to that same snapshot, so a mirror found here is in all three.
[ -f "$GICKUP_CONF" ] || { echo "error: $GICKUP_CONF not found" >&2; exit 1; }
mapfile -t mirror_repos < <(gickup_include "$GICKUP_CONF")
[ ${#mirror_repos[@]} -gt 0 ] || { echo "error: no repos under include: in $GICKUP_CONF" >&2; exit 1; }
mirrors_missing=0
for r in "${mirror_repos[@]}"; do
  # ls without --recursive lists the directory's direct children, HEAD among
  # them, so a hit means the mirror itself was captured, not just its path.
  # Not grep -q: exiting on the first match can SIGPIPE restic, and pipefail
  # would turn that into a false MISSING.
  if restic -r "$LOCAL_REPO" --password-file "$PASSFILE" ls --tag nightly latest "$MIRROR_DIR/$r.git" 2>/dev/null \
      | grep -x "$MIRROR_DIR/$r.git/HEAD" >/dev/null; then
    printf 'mirror %-18s  in latest snapshot\n' "$r"
  else
    printf 'mirror %-18s  MISSING from latest snapshot\n' "$r" >&2
    mirrors_missing=1
  fi
done

if [ -z "$local_t" ] || [ -z "$array_t" ] || [ -z "$b2_t" ]; then
  echo "OUT OF SYNC — at least one leg has no nightly snapshots" >&2
  exit 1
elif [ "$local_t" = "$array_t" ] && [ "$local_t" = "$b2_t" ]; then
  echo "IN SYNC — local, array mirror, and B2 hold the identical nightly snapshot"
else
  echo "OUT OF SYNC — one or more legs are behind" >&2
  exit 1
fi

if [ "$mirrors_missing" -ne 0 ]; then
  echo "MIRRORS MISSING — a whitelisted GitHub repo isn't in the backups yet;" \
       "check docker logs gickup, or wait for the next 03:00 run if it was just added" >&2
  exit 1
fi
