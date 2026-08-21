#!/usr/bin/env bash
# boot-reconcile.sh — start whatever failed to come up at boot, and complain
# loudly if anything is still down.
#
# Docker restores containers as soon as dockerd starts, which on this box is
# before tailscaled has finished assigning the tailnet address. Every service
# that binds a host port to ${TAILSCALE_IP} (vikunja, immich-server, grafana,
# prometheus) then dies with `cannot assign requested address` — on the
# 2026-08-20 auto-reboot dockerd lost that race by about 1.5 seconds, and all
# four stayed down for seven hours.
#
# `restart: unless-stopped` does not cover this. A restart policy applies to a
# container that exits *after running*; one that fails to *start* during daemon
# restore is logged once and left stopped, with no retry. Nothing on the box
# heals it, and the reboot is unattended by definition.
#
# So: wait for the address, then `up -d`. Deliberately not redeploy.sh — no
# pull, no rebuild, no prune belongs in the boot path. Run from
# homelab-boot-reconcile.service; safe to run by hand any time, it is a no-op
# when everything is already up.
#
# Override the repo location with HOMELAB_DIR (default: /opt/homelab).

set -euo pipefail

REPO_DIR="${HOMELAB_DIR:-/opt/homelab}"
cd "$REPO_DIR"

# How long to wait for tailscaled. Generous — losing the race costs a service
# for hours, waiting costs a few seconds of boot.
TAILSCALE_WAIT_SECS=60

echo "==> waiting for the tailnet address (up to ${TAILSCALE_WAIT_SECS}s)"
deadline=$(( $(date +%s) + TAILSCALE_WAIT_SECS ))
tailscale_ip=""
while [ -z "$tailscale_ip" ] && [ "$(date +%s)" -lt "$deadline" ]; do
  # `tailscale ip -4` exits nonzero while the interface has no address yet, so
  # it doubles as the readiness check. Not `tailscale status`: that reports the
  # backend as Running slightly before the address lands on tailscale0.
  tailscale_ip="$(tailscale ip -4 2>/dev/null || true)"
  [ -n "$tailscale_ip" ] || sleep 1
done

if [ -n "$tailscale_ip" ]; then
  echo "    tailnet address is up: $tailscale_ip"
else
  # Don't bail. If tailscale is genuinely dead the `up -d` below fails on the
  # four ${TAILSCALE_IP} services and the check at the end turns that into a
  # unit failure — which is the signal we want, rather than a silent skip.
  echo "warning: no tailnet address after ${TAILSCALE_WAIT_SECS}s — continuing anyway" >&2
fi

echo "==> starting anything that is not running"
docker compose up -d

# Derived from the compose config rather than copied from healthcheck.sh's
# CONTAINERS, so adding an app can't leave this check silently blind to it.
# Same extraction redeploy.sh uses to spot strays.
echo "==> verifying every container is running"
down=()
while read -r name; do
  [ -n "$name" ] || continue
  if [ -z "$(docker ps -q -f "name=^${name}$")" ]; then
    down+=("$name")
  fi
done < <(docker compose config | sed -n 's/^[[:space:]]*container_name: *//p')

if [ "${#down[@]}" -gt 0 ]; then
  echo "error: still not running after reconcile: ${down[*]}" >&2
  echo "  check: docker compose logs --tail 50 ${down[*]}" >&2
  # Fail the unit so this shows up in `systemctl --failed` and the journal
  # instead of a boot that looks clean while a service is missing.
  exit 1
fi

echo "==> all containers running"
