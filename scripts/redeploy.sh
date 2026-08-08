#!/usr/bin/env bash
# redeploy.sh — bring the stack up to date and (re)start whatever changed.
#
# `docker compose up -d` alone is enough for every image-based service —
# watchtower already pulls and restarts those on its own schedule. talkomatic
# is the exception: it builds from a remote git context
# (talkomatic/docker-compose.yml) instead of pulling a registry image, and is
# explicitly excluded from watchtower since watchtower can't rebuild a git
# context. Compose also only builds an image when one is missing, so a plain
# `up -d` would silently keep serving whatever talkomatic image was last
# built. This script forces that rebuild every run so upstream
# talkomatic-classic commits actually land.
#
# Override the repo location with HOMELAB_DIR (default: /opt/homelab).

set -euo pipefail

REPO_DIR="${HOMELAB_DIR:-/opt/homelab}"
cd "$REPO_DIR"

echo "==> pulling registry images"
docker compose pull

echo "==> rebuilding talkomatic from latest talkomatic-classic main"
docker compose build --pull talkomatic

echo "==> starting stack"
docker compose up -d --remove-orphans

echo "==> forcing talkomatic to pick up the new build"
docker compose up -d --force-recreate talkomatic

echo "==> status"
docker compose ps
