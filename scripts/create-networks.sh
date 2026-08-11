#!/usr/bin/env bash
# Idempotently create the external Docker networks this stack depends on, with
# pinned subnets. Every compose file declares these `external: true`, so
# `docker compose up` fails outright before touching anything if one is
# missing — this is the missing prerequisite for a rebuild from scratch.
#
# The proxy subnet specifically is not optional: traefik/traefik.yml
# hardcodes `trustedIPs: 172.20.0.0/16`. If Docker assigns a different subnet
# here, traefik silently stops trusting forwarded headers and every service
# sees the proxy's address as the client IP instead of the real one — nothing
# errors, the rate-limit middleware just starts keying on the wrong address.
set -euo pipefail

declare -A NETWORKS=(
  [proxy]=172.20.0.0/16
  [db_internal]=172.18.0.0/16
  [monitoring_internal]=172.22.0.0/16
)

for net in "${!NETWORKS[@]}"; do
  subnet="${NETWORKS[$net]}"
  existing=$(docker network inspect "$net" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)
  if [ -z "$existing" ]; then
    echo "creating $net ($subnet)"
    docker network create --subnet "$subnet" "$net"
  elif [ "$existing" != "$subnet" ]; then
    echo "warning: $net exists with subnet $existing, expected $subnet — not touching it." >&2
    echo "  fixing it means disconnecting every attached container:" >&2
    echo "    docker compose down && docker network rm $net && $0 && docker compose up -d" >&2
  else
    echo "$net already correct ($subnet)"
  fi
done
