#!/usr/bin/env bash
set -euo pipefail

# Verifies the Pi backup target actually holds what it claims to. A
# reachable repo with a recent snapshot (what healthcheck.sh checks) proves
# the nightly run completed, not that the Immich library landed on it intact
# — a wrong SOURCES_PI path or an over-broad exclude would still produce a
# fresh, green snapshot. This checks the data itself. See
# docs/pi-backup.md#verification.

REPO_DIR="${HOMELAB_DIR:-/opt/homelab}"
PASSFILE=/root/.restic-password
PI_ENV=/root/.restic-pi.env
MAX_SNAPSHOT_AGE_DAYS=2

if [ "$EUID" -ne 0 ]; then
  echo "error: run this with sudo — it reads $PASSFILE and $PI_ENV" >&2
  exit 1
fi

[ -f "$PI_ENV" ] || {
  echo "error: $PI_ENV not found — Pi backup target not configured, see docs/pi-backup.md" >&2
  exit 1
}
set -a
# shellcheck source=/dev/null
. "$PI_ENV"
set +a
: "${PI_REPO:?not set in $PI_ENV}"

env_value() {
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -1 | tr -d "\"'"
}
UPLOAD_LOCATION=$(env_value "$REPO_DIR/immich/.env" UPLOAD_LOCATION)
: "${UPLOAD_LOCATION:?UPLOAD_LOCATION not set in $REPO_DIR/immich/.env}"

echo "== snapshot freshness =="
latest=$(restic -r "$PI_REPO" --password-file "$PASSFILE" snapshots --tag nightly --latest 1 --json \
  | grep -o '"time":"[^"]*"' | cut -d'"' -f4 | sort -r | head -1)
[ -n "$latest" ] || { echo "error: cannot read the Pi repo, or it has no snapshots" >&2; exit 1; }
age=$(( ( $(date +%s) - $(date -d "$latest" +%s) ) / 86400 ))
echo "latest snapshot: $latest (${age}d old)"
if [ "$age" -gt "$MAX_SNAPSHOT_AGE_DAYS" ]; then
  echo "error: snapshot is ${age}d old — nightly Pi backups may have stopped" >&2
  exit 1
fi

echo; echo "== Immich file count: live vs snapshot =="
live_count=$(find "$UPLOAD_LOCATION" -type f | wc -l)
snap_count=$(restic -r "$PI_REPO" --password-file "$PASSFILE" ls latest --path "$UPLOAD_LOCATION" 2>/dev/null \
  | grep -c '^/' || true)
echo "live:     $live_count files"
echo "snapshot: $snap_count files"
if [ "$snap_count" -eq 0 ]; then
  echo "error: snapshot shows zero files under $UPLOAD_LOCATION — check SOURCES_PI/EXCLUDES in backup.sh" >&2
  exit 1
fi
# The live tree only grows between nightly runs, so it's expected to be
# slightly ahead of last night's snapshot — flag it only if the gap is large
# enough to suggest files are being missed rather than just uploaded today.
if [ "$live_count" -gt "$snap_count" ]; then
  gap=$(( live_count - snap_count ))
  threshold=$(( live_count / 20 )) # 5%
  if [ "$gap" -gt "$threshold" ]; then
    echo "warning: live has ${gap} more files than the snapshot (>5%) —" \
         "check whether backups are keeping up" >&2
  fi
fi

echo; echo "== Immich library size: live vs snapshot (restore-size) =="
live_size=$(du -sb "$UPLOAD_LOCATION" | cut -f1)
snap_size=$(restic -r "$PI_REPO" --password-file "$PASSFILE" stats latest --path "$UPLOAD_LOCATION" \
  --mode restore-size --json 2>/dev/null | grep -o '"total_size":[0-9]*' | cut -d: -f2)
echo "live:     $(numfmt --to=iec "$live_size")"
echo "snapshot: $(numfmt --to=iec "${snap_size:-0}")"
if [ -z "${snap_size:-}" ] || [ "$snap_size" -eq 0 ]; then
  echo "error: could not read snapshot size" >&2
  exit 1
fi

echo; echo "== data integrity (5% sample) =="
# Same sampling B2 uses, but for a different reason: reads over Tailscale-LAN
# aren't metered like B2's are, this is here to catch a degrading SSD rather
# than to save egress. Bump to a full --read-data occasionally by hand if
# the Pi's SSD is due for a closer look.
restic -r "$PI_REPO" --password-file "$PASSFILE" check --read-data-subset=5%

echo; echo "Pi backup verification passed"
