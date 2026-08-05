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
MOUNTS="/ /srv/docker-data /mnt/backup"
PUBLIC_URLS="https://${VIKUNJA_DOMAIN} https://${IMMICH_DOMAIN}"
LOCAL_REPO=/mnt/backup/restic-repo
PASSFILE=/root/.restic-password

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

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
restic -r "$LOCAL_REPO" --password-file "$PASSFILE" snapshots --latest 1 2>/dev/null | tail -2 \
  || bad "cannot read local repository"

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
