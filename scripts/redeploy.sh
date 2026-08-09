#!/usr/bin/env bash
# redeploy.sh — bring the stack up to date and (re)start whatever changed.
#
# `docker compose up -d` alone is enough for every image-based service —
# watchtower already pulls and restarts those on its own schedule. talkomatic
# and talkomatic-bot are the exception: they build from source (talkomatic
# from a remote git context, talkomatic-bot from the local talkomatic-bot/app
# Dockerfile) instead of pulling a registry image, and are explicitly
# excluded from watchtower since watchtower can't rebuild either kind of
# build context. Compose also only builds an image when one is missing, so a
# plain `up -d` would silently keep serving whatever image was last built.
# This script forces both rebuilds every run so upstream talkomatic-classic
# commits and local bot code changes actually land.
#
# Override the repo location with HOMELAB_DIR (default: /opt/homelab).

set -euo pipefail

REPO_DIR="${HOMELAB_DIR:-/opt/homelab}"
cd "$REPO_DIR"

# Networks marked `external: true` in a compose file are a promise, not a
# request — compose expects them to already exist and fails `up` before
# touching anything if one doesn't. Docker has no idempotent "create if
# missing", so check first; a plain `network create` errors on a network
# that's already there.
EXTERNAL_NETWORKS=(proxy db_internal monitoring_internal)
echo "==> ensuring external networks exist"
for net in "${EXTERNAL_NETWORKS[@]}"; do
  docker network inspect "$net" >/dev/null 2>&1 || docker network create "$net"
done

echo "==> pulling registry images"
docker compose pull

echo "==> rebuilding talkomatic from latest talkomatic-classic main"
docker compose build --pull talkomatic

echo "==> rebuilding talkomatic-bot from local source"
docker compose build --pull talkomatic-bot

echo "==> starting stack"
docker compose up -d --remove-orphans

echo "==> forcing talkomatic and talkomatic-bot to pick up the new builds"
docker compose up -d --force-recreate talkomatic talkomatic-bot

echo "==> pruning dangling images and build cache"
docker image prune -f
docker builder prune -f

echo "==> status"
docker compose ps
