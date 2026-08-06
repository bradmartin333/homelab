#!/usr/bin/env bash
set -euo pipefail

# Create the external docker networks the stack expects. Idempotent — safe to
# re-run, and safe to run before every `docker compose up`.
#
# The compose files declare both networks as `external: true`, so nothing in the
# stack creates them. Without this, a rebuild fails at the first `docker compose
# up` with "network proxy declared as external, but could not be found".
#
# PROXY_SUBNET is not cosmetic. traefik/traefik.yml pins
# `forwardedHeaders.trustedIPs` to this range; if docker picks its own subnet
# instead, traefik silently stops trusting forwarded headers and every service
# sees the proxy's address as the client address. Nothing errors — the
# rate-limit middleware just starts keying on the wrong IP.

PROXY_SUBNET=172.20.0.0/16

create() {
  local name=$1
  shift
  if docker network inspect "$name" >/dev/null 2>&1; then
    echo "exists: $name"
  else
    docker network create "$@" "$name"
    echo "created: $name"
  fi
}

create proxy --subnet "$PROXY_SUBNET"
create db_internal

# Report the effective subnet rather than only complaining on mismatch. Staying
# quiet on success would make "couldn't read it" look identical to "it's fine",
# which is the exact failure mode this check exists to catch.
#
# A mismatch warns rather than fails: recreating the network disconnects every
# attached container, so that's a deliberate decision, not an automatic one.
actual=$(docker network inspect proxy -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
if [ -z "$actual" ]; then
  echo "warning: could not read the proxy network's subnet — cannot confirm it" \
       "matches the $PROXY_SUBNET that traefik.yml trusts" >&2
elif [ "$actual" = "$PROXY_SUBNET" ]; then
  echo "subnet:  proxy is $actual, matching traefik.yml trustedIPs"
else
  cat >&2 <<EOF
warning: proxy network is $actual, but traefik.yml trusts $PROXY_SUBNET.
         Forwarded headers are not being trusted — every service sees the
         proxy's address as the client address. To fix, with downtime:
           docker compose -f /opt/homelab/docker-compose.yml down
           docker network rm proxy
           $0
           docker compose -f /opt/homelab/docker-compose.yml up -d
EOF
fi
