#!/usr/bin/env bash
# redeploy.sh — bring the stack up to date and (re)start whatever changed.
#
# `docker compose up -d` alone is enough for every image-based service —
# watchtower already pulls and restarts those on its own schedule. meals is the
# exception: it builds from source (a remote git context) instead of pulling a
# registry image, and is explicitly excluded from watchtower since watchtower
# can't rebuild a build context. Compose also only builds an image when one is
# missing, so a plain `up -d` would silently keep serving whatever image was
# last built. This script forces that rebuild every run so upstream meals
# commits actually land.
#
# Override the repo location with HOMELAB_DIR (default: /opt/homelab).

set -euo pipefail

if [ "$#" -gt 0 ]; then
  echo "usage: $0" >&2
  exit 1
fi

REPO_DIR="${HOMELAB_DIR:-/opt/homelab}"
cd "$REPO_DIR"

# Subnets are pinned, not just "exists" — see create-networks.sh for why an
# unpinned `docker network create` silently breaks traefik's trusted-IP
# forwarding on the proxy network.
echo "==> ensuring external networks exist"
"$REPO_DIR/scripts/create-networks.sh"

echo "==> pulling registry images"
docker compose pull

# meals builds from someone else's repo, so a broken upstream push or a
# GitHub outage must not block the rest of the redeploy. On failure, leave
# meals out of the `up` calls below (its pull_policy: build would otherwise
# make `up` retry the build) so its current container keeps running.
echo "==> rebuilding meals from latest marco308/meals main"
MEALS_OK=true
EXCLUDE=()
if ! docker compose build --pull meals; then
  MEALS_OK=false
  echo "warning: meals build failed — keeping the current meals container" >&2
  EXCLUDE+=(meals)
fi

# An empty UP_SERVICES means "every service".
UP_SERVICES=()
if [ ${#EXCLUDE[@]} -gt 0 ]; then
  mapfile -t UP_SERVICES < <(docker compose config --services | grep -vxF -f <(printf '%s\n' "${EXCLUDE[@]}"))
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
  # --no-trunc: `docker compose ps -q` prints full IDs, and a short one
  # never matches them, so every container looked stray.
  cid="$(docker ps -aq --no-trunc -f "name=^${name}$")"
  if [ -n "$cid" ] && ! grep -qx "$cid" <<<"$IN_PROJECT"; then
    echo "  removing stray container: $name ($cid)"
    docker rm -f "$cid"
  fi
done

echo "==> starting stack"
docker compose up -d --remove-orphans "${UP_SERVICES[@]}"

# `up -d` only recreates a container when its definition changes (image,
# env, mounts, ...) — it can't see that prometheus.yml's *contents*
# changed on disk, since the bind mount itself is unchanged. Reload it
# every run to pick up scrape-config edits. A reload (--web.enable-lifecycle)
# keeps the TSDB open, where a restart left a gap in every series. Retried
# because `up -d` may have just recreated prometheus and it isn't listening
# yet. A bad prometheus.yml fails the reload and keeps the old config
# running, so warn rather than abort the rest of the redeploy.
echo "==> reloading prometheus to pick up prometheus.yml changes"
reloaded=false
for _ in 1 2 3 4 5 6; do
  if docker compose exec -T prometheus wget -qO- --post-data='' http://localhost:9090/-/reload; then
    reloaded=true; break
  fi
  sleep 5
done
$reloaded || echo "warning: prometheus reload failed — check: docker logs prometheus" >&2

if $MEALS_OK; then
  echo "==> forcing meals to pick up the new build"
  docker compose up -d --force-recreate meals
fi

echo "==> pruning dangling images and build cache"
docker image prune -f
docker builder prune -f

echo "==> status"
docker compose ps

if ! $MEALS_OK; then
  echo "warning: meals was NOT rebuilt — see the build error above" >&2
  exit 1
fi
