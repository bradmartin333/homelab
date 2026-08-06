#!/usr/bin/env bash

set -uo pipefail

REPO_DIR="${HOMELAB_DIR:-/opt/homelab}"

if [ "$EUID" -ne 0 ]; then
  echo "error: run this with sudo — mdadm, smartctl, and restic all need root" >&2
  exit 1
fi

if [ -f "$REPO_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
else
  echo "error: $REPO_DIR/.env not found (set HOMELAB_DIR to override)" >&2
  exit 1
fi

CONTAINERS="traefik postgres vikunja cloudflared watchtower immich-server immich-machine-learning immich-redis immich-postgres"
MOUNTS="/ /srv/docker-data /srv/media"
# Subset of MOUNTS that must be a real mount, not a directory on the root
# filesystem. If sdb or md0 fails to come up, the path still exists and both
# the stack and restic would silently write to the OS disk instead.
REQUIRED_MOUNTPOINTS="/srv/docker-data /srv/media"
PUBLIC_URLS="https://${VIKUNJA_DOMAIN} https://${IMMICH_DOMAIN}"
LOCAL_REPO=/srv/docker-data/restic-repo
ARRAY_REPO=/srv/media/restic-mirror
PASSFILE=/root/.restic-password
B2_ENV=/root/.restic-b2.env
STAGING=/var/lib/homelab-backup-staging
MAX_SNAPSHOT_AGE_DAYS=2
# Backblaze gives 10 GB free. Warn with headroom left to trim retention before
# the bill starts rather than after.
B2_WARN_BYTES=$((8 * 1024 * 1024 * 1024))

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

# Age in whole days of the newest snapshot in a repo, or empty if the repo is
# unreadable or has none. Parsed out of --json so we don't need jq installed.
snapshot_age_days() {
  local repo=$1 when
  when=$(restic -r "$repo" --password-file "$PASSFILE" snapshots --latest 1 --json 2>/dev/null \
    | grep -o '"time":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -n "$when" ] || return 0
  echo $(( ( $(date +%s) - $(date -d "$when" +%s) ) / 86400 ))
}

check_repo() {
  local label=$1 repo=$2 age
  age=$(snapshot_age_days "$repo")
  if   [ -z "$age" ];                          then bad  "$label — cannot read repository or no snapshots"
  elif [ "$age" -gt "$MAX_SNAPSHOT_AGE_DAYS" ]; then bad  "$label — newest snapshot is ${age}d old"
  else                                              ok   "$label — newest snapshot ${age}d old"
  fi
}

echo; echo "CONTAINERS"
for c in $CONTAINERS; do
  state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  [ "$state" = "running" ] && ok "$c" || bad "$c is $state"
done
looping=$(docker ps --filter status=restarting -q | wc -l)
[ "$looping" -eq 0 ] && ok "nothing restart-looping" || bad "$looping restart-looping"

echo; echo "DATABASE"
docker exec postgres pg_isready -q 2>/dev/null \
  && ok "postgres accepting connections" || bad "postgres not accepting connections"
docker exec immich-postgres pg_isready -q 2>/dev/null \
  && ok "immich-postgres accepting connections" || bad "immich-postgres not accepting connections"

echo; echo "DISK"
for m in $MOUNTS; do
  pct=$(df --output=pcent "$m" 2>/dev/null | tail -1 | tr -dc '0-9')
  if   [ -z "$pct" ];     then bad  "$m not mounted"
  elif [ "$pct" -ge 85 ]; then warn "$m ${pct}% used"
  else                         ok   "$m ${pct}% used"
  fi
done
for m in $REQUIRED_MOUNTPOINTS; do
  mountpoint -q "$m" \
    && ok "$m is a real mount" \
    || bad "$m is a directory on / — its disk did not mount"
done

echo; echo "DRIVES"
for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'); do
  smartctl -H "$d" >/dev/null 2>&1 \
    && ok "$d SMART healthy" || warn "$d SMART problem — run: smartctl -a $d"
done

echo; echo "RAID"
if grep -qs '^md' /proc/mdstat; then
  for md in $(grep -oE '^md[0-9]+' /proc/mdstat); do
    mdadm --detail --test "/dev/$md" >/dev/null 2>&1 \
      && ok "$md clean" || bad "$md degraded — run: mdadm --detail /dev/$md"
  done
else
  ok "no software RAID configured"
fi

echo; echo "BACKUPS"
code=$(systemctl show homelab-backup.service -p ExecMainStatus --value)
when=$(systemctl show homelab-backup.service -p ExecMainExitTimestamp --value)
if   [ -z "$when" ];    then warn "homelab-backup.service has never run — check: systemctl list-timers | grep homelab-backup"
elif [ "$code" = "0" ]; then ok "last run clean — $when"
else                         bad "last run exit=$code — $when"
fi

for f in "$STAGING/pg_dumpall.sql" "$STAGING/immich_pg_dumpall.sql"; do
  name=$(basename "$f")
  if [ ! -f "$f" ]; then
    bad "$name missing"
  elif ! tail -5 "$f" | grep -q 'PostgreSQL database cluster dump complete'; then
    bad "$name is truncated — no completion trailer"
  else
    age=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 86400 ))
    [ "$age" -le "$MAX_SNAPSHOT_AGE_DAYS" ] \
      && ok "$name ${age}d old, $(du -h "$f" | cut -f1)" \
      || bad "$name is ${age}d old"
  fi
done

check_repo "local repo (sdb)" "$LOCAL_REPO"
check_repo "array mirror (md0)" "$ARRAY_REPO"
if [ -f "$B2_ENV" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$B2_ENV"
  set +a
  if [ -n "${RESTIC_B2_REPO:-}" ]; then
    check_repo "backblaze repo" "$RESTIC_B2_REPO"
    # Staying under 10 GB is the whole reason this fits in the free tier.
    used=$(restic -r "$RESTIC_B2_REPO" --password-file "$PASSFILE" \
      stats --mode raw-data --json 2>/dev/null \
      | grep -o '"total_size":[0-9]*' | cut -d: -f2)
    if [ -z "$used" ]; then
      warn "could not read backblaze repo size"
    elif [ "$used" -ge "$B2_WARN_BYTES" ]; then
      warn "backblaze repo $(numfmt --to=iec "$used") — free tier is 10G, trim B2_KEEP in backup.sh"
    else
      ok "backblaze repo $(numfmt --to=iec "$used") of 10G free tier"
    fi
  else
    bad "RESTIC_B2_REPO not set in $B2_ENV"
  fi
else
  bad "$B2_ENV not found — offsite copy is not configured"
fi

echo; echo "NETWORK"
tailscale status >/dev/null 2>&1 && ok "tailscale connected" || bad "tailscale down"
for url in $PUBLIC_URLS; do
  curl -sfI --max-time 15 "$url" >/dev/null \
    && ok "$url responding" || bad "$url not responding"
done

echo; echo "UPDATES"
pending=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
[ "$pending" -eq 0 ] && ok "no packages pending" || warn "$pending packages upgradable"
[ -f /var/run/reboot-required ] && warn "reboot required" || ok "no reboot pending"
echo
