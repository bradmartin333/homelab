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
# Starting them again is not enough either. A container that fails to start
# during restore can come back missing networks: after the 2026-09-15 reboot
# all four had lost their internal network (vikunja lost db_internal, grafana
# was left with none). Their compose config hadn't changed, so a plain `up -d`
# restarted the same broken containers, and vikunja crash-looped on
# `lookup postgres` while this script reported success.
#
# So: wait for the address, recreate whatever isn't running from the compose
# file, `up -d` everything else, and give the result time to crash before
# calling it healthy. Deliberately not redeploy.sh — no pull, no rebuild, no
# prune belongs in the boot path. Run from homelab-boot-reconcile.service;
# safe to run by hand any time, it changes nothing when everything is already
# up.
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

# Every `up` below passes --no-build. meals sets `pull_policy: build`, which
# makes a plain `up` rebuild it from upstream main — so a boot would silently
# swap in whatever someone else pushed, mid-reconcile. Booting is for getting
# back to the last known-good state; picking up new upstream code is
# redeploy.sh's job, run deliberately.

# `--status running` excludes `restarting`, so a container caught in a crash
# loop when this is run by hand gets recreated too.
mapfile -t not_running < <(comm -23 \
  <(docker compose config --services | sort) \
  <(docker compose ps --services --status running | sort))

if [ "${#not_running[@]}" -gt 0 ]; then
  echo "==> recreating what is not running: ${not_running[*]}"
  # Forces only the named services. Compose recreates their dependencies only
  # if those have diverged from the config, so postgres keeps running under a
  # recreated vikunja.
  docker compose up -d --no-build --force-recreate "${not_running[@]}"
fi

echo "==> starting anything else"
docker compose up -d --no-build

# A crash-looping container is `running` for the moment after each restart;
# the 2026-09-15 run checked once, a second after `up`, and passed with vikunja
# looping. So record restart counts, wait, and require that none moved.
SETTLE_SECS=30

# Derived from the compose config rather than copied from healthcheck.sh's
# CONTAINERS, so adding an app can't leave this check silently blind to it.
# Same extraction redeploy.sh uses to spot strays.
mapfile -t containers < <(docker compose config | sed -n 's/^[[:space:]]*container_name: *//p')

declare -A restarts_before=()
for name in "${containers[@]}"; do
  restarts_before[$name]="$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo missing)"
done

echo "==> waiting ${SETTLE_SECS}s, then verifying every container stayed up"
sleep "$SETTLE_SECS"

bad=()
for name in "${containers[@]}"; do
  if ! state="$(docker inspect -f '{{.State.Status}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null)"; then
    bad+=("$name: missing")
    continue
  fi
  read -r status count health <<<"$state"
  if [ "$status" != running ]; then
    bad+=("$name: $status")
  elif [ "$count" != "${restarts_before[$name]}" ]; then
    bad+=("$name: restarted during the check (restart count ${restarts_before[$name]} -> $count)")
  elif [ "$health" = unhealthy ]; then
    bad+=("$name: unhealthy")
  fi
done

if [ "${#bad[@]}" -gt 0 ]; then
  echo "error: not healthy after reconcile:" >&2
  printf '  %s\n' "${bad[@]}" >&2
  echo "  check: docker logs --tail 50 <name>" >&2
  # Fail the unit so this shows up in `systemctl --failed` and the journal
  # instead of a boot that looks clean while a service is missing.
  exit 1
fi

echo "==> all containers running"
