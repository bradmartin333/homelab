#!/usr/bin/env bash
# redeploy.sh — bring the stack up to date and (re)start whatever changed.
#
# `docker compose up -d` alone is enough for every image-based service —
# watchtower already pulls and restarts those on its own schedule. talkomatic,
# talkomatic-bot, and meals are the exception: they build from source
# (talkomatic and meals from a remote git context, talkomatic-bot from the
# local talkomatic-bot/app Dockerfile) instead of pulling a registry image,
# and are explicitly excluded from watchtower since watchtower can't rebuild
# any of these build contexts. Compose also only builds an image when one is
# missing, so a plain `up -d` would silently keep serving whatever image was
# last built. This script forces all three rebuilds every run so upstream
# talkomatic-classic/meals commits and local bot code changes actually land.
#
# talkomatic-ops (tools/ops.js's bots sidecar) rides along with talkomatic's
# rebuild for free - it shares talkomatic's `image:` tag with no `build:` of
# its own, so rebuilding talkomatic already refreshes it. It still needs an
# explicit --force-recreate below since a new image alone doesn't restart a
# running container.
#
# Override the repo location with HOMELAB_DIR (default: /opt/homelab).
# Pass --chat-only (or -c) to rebuild and restart just talkomatic,
# talkomatic-ops, and talkomatic-bot — skips the network check and
# full-stack pull/up, for when the rest of the stack is already running and
# doesn't need to come down.

set -euo pipefail

CHAT_ONLY=false
case "${1:-}" in
  --chat-only|-c) CHAT_ONLY=true ;;
  "") ;;
  *) echo "usage: $0 [--chat-only|-c]" >&2; exit 1 ;;
esac

REPO_DIR="${HOMELAB_DIR:-/opt/homelab}"
cd "$REPO_DIR"

if ! $CHAT_ONLY; then
  # Subnets are pinned, not just "exists" — see create-networks.sh for why an
  # unpinned `docker network create` silently breaks traefik's trusted-IP
  # forwarding on the proxy network.
  echo "==> ensuring external networks exist"
  "$REPO_DIR/scripts/create-networks.sh"

  echo "==> pulling registry images"
  docker compose pull
fi

echo "==> rebuilding talkomatic from latest talkomatic-classic main"
docker compose build --pull talkomatic

echo "==> rebuilding talkomatic-bot from local source"
docker compose build --pull talkomatic-bot

if ! $CHAT_ONLY; then
  # meals builds from someone else's repo, so a broken upstream push or a
  # GitHub outage must not block the rest of the redeploy. On failure, leave
  # meals out of the `up` calls below (its pull_policy: build would otherwise
  # make `up` retry the build) so its current container keeps running.
  echo "==> rebuilding meals from latest marco308/meals main"
  MEALS_OK=true
  UP_SERVICES=()
  if ! docker compose build --pull meals; then
    MEALS_OK=false
    echo "warning: meals build failed — keeping the current meals container" >&2
    mapfile -t UP_SERVICES < <(docker compose config --services | grep -vx meals)
  fi

  # Every service pins a fixed container_name, but that name is global to the
  # Docker daemon, not scoped to this compose project. Running `docker
  # compose` from inside a service's own subdirectory (e.g. to test one
  # service in isolation) creates a container under a *different* project
  # that still claims the same name, so a later `up -d` here fails with a
  # name conflict instead of recreating it. Clear any such stray containers
  # first so redeploys are self-healing regardless of how the name got taken.
  echo "==> clearing stray containers left by out-of-project compose runs"
  IN_PROJECT="$(docker compose ps -aq)"
  docker compose config | sed -n 's/^[[:space:]]*container_name: *//p' | while read -r name; do
    cid="$(docker ps -aq -f "name=^${name}$")"
    if [ -n "$cid" ] && ! grep -qx "$cid" <<<"$IN_PROJECT"; then
      echo "  removing stray container: $name ($cid)"
      docker rm -f "$cid"
    fi
  done

  echo "==> starting stack"
  docker compose up -d --remove-orphans "${UP_SERVICES[@]}"

  # `up -d` only recreates a container when its definition changes (image,
  # env, mounts, ...) — it can't see that prometheus.yml's *contents*
  # changed on disk, since the bind mount itself is unchanged. Prometheus
  # only reads that file at startup, so force a restart every run to pick
  # up scrape-config edits.
  echo "==> restarting prometheus to pick up prometheus.yml changes"
  docker compose restart prometheus

  if $MEALS_OK; then
    echo "==> forcing meals to pick up the new build"
    docker compose up -d --force-recreate meals
  fi
fi

echo "==> forcing talkomatic, talkomatic-ops, and talkomatic-bot to pick up the new builds"
docker compose up -d --force-recreate talkomatic talkomatic-ops talkomatic-bot

echo "==> pruning dangling images and build cache"
docker image prune -f
docker builder prune -f

echo "==> status"
docker compose ps

if ! $CHAT_ONLY && ! $MEALS_OK; then
  echo "warning: meals was NOT rebuilt — see the build error above" >&2
  exit 1
fi
