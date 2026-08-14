#!/usr/bin/env bash
set -euo pipefail

# Nightly backup: dump both postgres clusters, snapshot to the local restic
# repo on the sdb SSD, then copy that snapshot offsite to Backblaze B2.
#
# Immich's media library is deliberately excluded — it lives on the md0 mirror
# at /srv/media, it is far too large to be worth B2 egress, and the remote rPi
# replica covers it instead. Everything needed to rebuild the stack around a
# restored library is here.

REPO_DIR="${HOMELAB_DIR:-/opt/homelab}"
# The repo lives on the same filesystem as /srv/docker-data because sdb is one
# volume — hence the self-exclude further down, and hence why the disk-usage
# warning in healthcheck.sh matters: a repo left to grow fills the disk that
# postgres is writing to.
LOCAL_REPO=/srv/docker-data/restic-repo
# Mirror of LOCAL_REPO on the md0 array. Moving the repo onto sdb put it on the
# same unmirrored disk as the data it protects; this ~123M copy buys that
# redundancy back, so a dead sdb is a local restore rather than a B2 download.
ARRAY_REPO=/srv/media/restic-mirror
PASSFILE=/root/.restic-password
B2_ENV=/root/.restic-b2.env
STAGING=/var/lib/homelab-backup-staging
# healthchecks.io ping UUID, kept out of this repo because it is public:
# anyone holding the UUID can POST a fake "backup succeeded" ping and
# suppress the one alert that tells you backups have stopped.
#   printf '%s\n' '<uuid>' > /root/.homelab-hc-uuid && chmod 600 /root/.homelab-hc-uuid
HC_UUID_FILE=/root/.homelab-hc-uuid
HC_UUID=$(cat "$HC_UUID_FILE" 2>/dev/null || true)
if [ -z "$HC_UUID" ]; then
  # Warn loudly but keep backing up — losing the dead man's switch is bad,
  # losing the backup itself is worse.
  echo "warning: $HC_UUID_FILE missing or empty — dead man's switch disabled" >&2
fi

# A pg_dumpall of even an empty cluster clears this comfortably, so anything
# smaller means the dump completed but came back hollow — wrong container,
# wrong user, or a cluster that lost its data.
MIN_DUMP_BYTES=4096

# This repo targets Backblaze's free tier: 10 GB stored, and free egress up to
# 3x stored per month. Uploads and deletes are free; downloads are what costs.
#
# The repo measured 123M in Aug 2026 — roughly 1% of the free allowance — so
# both copies keep the same history. If it ever grows enough to matter, trim
# B2_KEEP first: a shorter offsite history is a cheaper concession than a bill.
# prune still runs monthly rather than nightly, since it is the one routine
# operation that downloads.
LOCAL_KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)
B2_KEEP=("${LOCAL_KEEP[@]}")
B2_PRUNE_DOM=01 # day of month, per `date +%d`

# Pull one value out of a compose .env without sourcing the file — these
# contain database passwords we have no business dragging into this shell.
env_value() {
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -1 | tr -d "\"'"
}

UPLOAD_LOCATION=$(env_value "$REPO_DIR/immich/.env" UPLOAD_LOCATION)
IMMICH_DB_USER=$(env_value "$REPO_DIR/immich/.env" DB_USERNAME)
: "${IMMICH_DB_USER:=immich}"

# Only one backup at a time — a slow B2 copy must not overlap the next night's
# run and leave two resticks fighting over the same repo lock.
exec 9>/run/homelab-backup.lock
flock -n 9 || { echo "error: another backup is already running" >&2; exit 1; }

# Clear locks left behind by a run that died mid-flight — killed, OOM'd, or
# interrupted by hand. restic locks live in the repo, not in memory, so nothing
# releases them when the process goes away, and every later run fails at the
# same step until someone intervenes.
#
# Plain `unlock` is the safe form: it only removes locks older than restic's
# staleness window that were created on this host by a PID that no longer
# exists. It will not touch a lock a running restic holds. Never use
# --remove-all here — that deletes live locks too, and a nightly job that does
# so unattended will eventually corrupt a repo mid-write. The flock above
# already rules out a second backup of ours competing for these.
#
# This is quiet when there is nothing to clear. If it starts reporting removed
# locks every night, that means runs are dying and the next run is papering
# over it — go read the journal rather than letting it scroll past.
unlock_stale() {
  restic -r "$1" --password-file "$PASSFILE" unlock
}

# Ping the dead man's switch immediately on failure rather than letting the
# check time out hours later. The healthchecks.io check is configured with a
# 1-day period plus a few hours' grace, so silence means "the job stopped
# running or the box is off" and an explicit /fail means "it ran and broke" —
# see docs/operations.md.
STATUS_FILE="$STAGING/last-run-status"
hc_fail() { [ -n "$HC_UUID" ] || return 0; curl -fsS -m 10 --retry 3 "https://hc-ping.com/$HC_UUID/fail" >/dev/null || true; }
on_exit() {
  local rc=$?
  mkdir -p "$(dirname "$STATUS_FILE")"
  if [ "$rc" -eq 0 ]; then
    printf 'ok %s\n' "$(date -Iseconds)" > "$STATUS_FILE"
  else
    printf 'fail %s\n' "$(date -Iseconds)" > "$STATUS_FILE"
    hc_fail
  fi
}
trap on_exit EXIT TERM

# If sdb failed to mount, /srv/docker-data is a bare directory on the root
# filesystem — the databases would be missing and restic would write its repo
# to the OS disk. Refuse to run.
mountpoint -q /srv/docker-data || { echo "error: /srv/docker-data is not mounted" >&2; exit 1; }
mountpoint -q /srv/media || { echo "error: /srv/media is not mounted" >&2; exit 1; }
[ -d "$ARRAY_REPO" ] || {
  echo "error: $ARRAY_REPO does not exist — see docs/architecture-migration.md" >&2
  exit 1
}

mkdir -p "$STAGING"
chmod 700 "$STAGING"

# Dump to a temp file and move on success, so a failed dump can never
# replace last night's good one with a truncated file.
#
# Dumps are stored UNCOMPRESSED on purpose. restic chunks, dedupes, and
# compresses them itself, and last night's plain SQL differs from tonight's in
# only the rows that changed. Pre-gzipping defeats that completely — two gzip
# streams of near-identical input share almost no bytes, so every night would
# upload the dump in full and blow through the free tier in weeks.
dump_cluster() {
  local container=$1 user=$2 out=$3
  docker exec "$container" pg_dumpall --clean --if-exists -U "$user" > "$out.tmp"
  # pg_dumpall writes this trailer last thing, so its presence is proof the
  # dump ran to completion instead of dying partway through a table.
  if ! tail -5 "$out.tmp" | grep -q 'PostgreSQL database cluster dump complete'; then
    echo "error: $out.tmp has no completion trailer — the dump did not finish" >&2
    rm -f "$out.tmp"
    exit 1
  fi
  local size
  size=$(stat -c %s "$out.tmp")
  if [ "$size" -lt "$MIN_DUMP_BYTES" ]; then
    echo "error: $out is only ${size} bytes — refusing to promote it" >&2
    rm -f "$out.tmp"
    exit 1
  fi
  mv "$out.tmp" "$out"
}

dump_cluster postgres postgres "$STAGING/pg_dumpall.sql"
dump_cluster immich-postgres "$IMMICH_DB_USER" "$STAGING/immich_pg_dumpall.sql"

# Backing up /srv/docker-data wholesale means a service added later is covered
# by default instead of silently missing until the day it matters.
SOURCES=(
  "$STAGING"
  /opt/homelab
  /srv/docker-data
)

EXCLUDES=(
  # The repo sits inside the tree it is backing up — sdb is a single volume, so
  # there is nowhere on it that isn't under /srv/docker-data. Without this,
  # restic feeds its own output back into itself.
  --exclude "$LOCAL_REPO"
  # Live PGDATA copied hot is inconsistent and unrestorable; the dumps in
  # $STAGING are the real backup of these two clusters.
  --exclude /srv/docker-data/postgres
  --exclude /srv/docker-data/immich/postgres
)
# The library lives on /srv/media, which isn't in SOURCES, so this is belt and
# braces — it keeps the exclusion correct if /srv/media is ever added.
if [ -n "$UPLOAD_LOCATION" ]; then
  EXCLUDES+=(--exclude "$UPLOAD_LOCATION")
else
  echo "warning: UPLOAD_LOCATION not found in $REPO_DIR/immich/.env —" \
       "the Immich library may be getting swept into this backup" >&2
fi

unlock_stale "$LOCAL_REPO"
restic -r "$LOCAL_REPO" --password-file "$PASSFILE" \
  backup --tag nightly "${EXCLUDES[@]}" "${SOURCES[@]}"
restic -r "$LOCAL_REPO" --password-file "$PASSFILE" forget --tag nightly \
  "${LOCAL_KEEP[@]}" --prune
restic -r "$LOCAL_REPO" --password-file "$PASSFILE" check

# Mirror onto the array. Same disk-local speed as the source, so this keeps the
# same retention as LOCAL_REPO and prunes every night — none of the B2 cost
# reasoning applies here.
unlock_stale "$ARRAY_REPO"
restic -r "$ARRAY_REPO" --password-file "$PASSFILE" copy --tag nightly \
  --from-repo "$LOCAL_REPO" --from-password-file "$PASSFILE"
restic -r "$ARRAY_REPO" --password-file "$PASSFILE" forget --tag nightly \
  "${LOCAL_KEEP[@]}" --prune

# Offsite copy. B2 credentials and RESTIC_B2_REPO live outside the git repo.
set -a
# shellcheck source=/dev/null
. "$B2_ENV"
set +a
: "${RESTIC_B2_REPO:?not set in $B2_ENV}"

# This is the one that matters most in practice: B2 is the slowest step, so it
# is where an interrupted run is most likely to leave a lock behind — as it did
# on 2026-08-11, blocking every manual run afterwards.
unlock_stale "$RESTIC_B2_REPO"

# Both repos share $PASSFILE — copy needs to unlock the source and the target,
# and one password is one fewer thing to lose.
restic -r "$RESTIC_B2_REPO" --password-file "$PASSFILE" copy --tag nightly \
  --from-repo "$LOCAL_REPO" --from-password-file "$PASSFILE"

# forget alone only deletes snapshot files — free on B2. The prune that
# actually reclaims the space has to download and repack, so it waits for the
# first of the month.
restic -r "$RESTIC_B2_REPO" --password-file "$PASSFILE" forget --tag nightly "${B2_KEEP[@]}"
if [ "$(date +%d)" = "$B2_PRUNE_DOM" ]; then
  restic -r "$RESTIC_B2_REPO" --password-file "$PASSFILE" prune
  restic -r "$RESTIC_B2_REPO" --password-file "$PASSFILE" check
fi

# Only reached if every step above succeeded.
[ -n "$HC_UUID" ] && curl -fsS -m 10 --retry 3 "https://hc-ping.com/$HC_UUID" > /dev/null
exit 0
