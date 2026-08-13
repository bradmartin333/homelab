#!/usr/bin/env bash
# bot-ctl.sh — hot-swap talkomatic-bot personalities on a running container.
#
# Bot personality profiles live as drop-in files in talkomatic-bot/bots/*.env
# (see talkomatic-bot/bots/README.md). This script copies a chosen profile
# into that container's active-config slot and sends it SIGHUP, which the
# bot process picks up live — no restart, no rebuild.
#
# Usage:
#   bot-ctl.sh list                          List available profiles
#   bot-ctl.sh status [container]            Show the profile currently active on a container
#   bot-ctl.sh load <profile> [container]    Hot-swap a running container onto a profile
#
# <container> is optional in both commands and, when given, always goes
# last — omit it to default to the first running container matching
# "talkomatic-bot*". Whatever identifies the container (name, ID, or the
# default) is resolved to its canonical container name before touching
# bots/active/, since that's the name BOT_CONFIG_PATH is keyed on — passing
# a container ID would otherwise write an active file the running bot never
# reads, silently reporting success while doing nothing.
#
# Override the repo location with HOMELAB_DIR (default: /opt/homelab).

set -euo pipefail

REPO_DIR="${HOMELAB_DIR:-/opt/homelab}"
BOTS_DIR="$REPO_DIR/talkomatic-bot/bots"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  list                          List available profiles ($BOTS_DIR/*.env)
  status [container]            Show the profile currently active on a container
  load <profile> [container]    Copy the profile in and hot-reload the container

container defaults to the first running "talkomatic-bot*" container.
Repo location: $REPO_DIR (override with HOMELAB_DIR=/path/to/repo)
EOF
}

require_repo() {
  [ -d "$BOTS_DIR" ] || {
    echo "error: $BOTS_DIR not found (set HOMELAB_DIR to override)" >&2
    exit 1
  }
}

cmd_list() {
  local found=0
  for f in "$BOTS_DIR"/*.env; do
    [ -f "$f" ] || continue
    found=1
    basename "$f" .env
  done
  [ "$found" -eq 1 ] || echo "no profiles found in $BOTS_DIR" >&2
}

default_container() {
  local name
  name=$(docker ps --filter "name=talkomatic-bot" --format '{{.Names}}' | sort | head -n1)
  [ -n "$name" ] || {
    echo "error: no running talkomatic-bot container found (pass one explicitly)" >&2
    exit 1
  }
  echo "$name"
}

# Resolves a name/ID/default to the container's canonical name, so
# bots/active/ is always keyed the same way BOT_CONFIG_PATH expects
# regardless of what identified the container on the command line.
canonical_name() {
  local container="$1"
  docker inspect -f '{{.Name}}' "$container" 2>/dev/null | sed 's#^/##'
}

cmd_status() {
  local container="${1:-}"
  [ -n "$container" ] || container=$(default_container)
  local canonical
  canonical=$(canonical_name "$container") || { echo "error: no such container: $container" >&2; exit 1; }
  local active="$BOTS_DIR/active/$canonical.env"
  if [ ! -f "$active" ]; then
    echo "no profile loaded for '$canonical' (running on .env defaults)"
    return 0
  fi
  head -n 1 "$active" | sed 's/^# //'
}

cmd_load() {
  local profile="${1:?usage: $(basename "$0") load <profile> [container]}"
  local container="${2:-}"
  [ -n "$container" ] || container=$(default_container)
  local src="$BOTS_DIR/$profile.env"

  [ -f "$src" ] || { echo "error: no such profile: $profile ($src)" >&2; exit 1; }

  local running
  running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null) || {
    echo "error: no such container: $container" >&2
    exit 1
  }
  [ "$running" = "true" ] || { echo "error: container '$container' is not running" >&2; exit 1; }

  local canonical="$(canonical_name "$container")"
  local active="$BOTS_DIR/active/$canonical.env"

  mkdir -p "$BOTS_DIR/active"
  {
    echo "# profile: $profile (loaded $(date -u +%Y-%m-%dT%H:%M:%SZ) by bot-ctl.sh)"
    cat "$src"
  } > "$active.tmp"
  mv "$active.tmp" "$active"

  docker kill -s HUP "$container" >/dev/null
  echo "loaded '$profile' onto '$canonical'"
}

require_repo

case "${1:-}" in
  list) cmd_list ;;
  status)
    shift
    cmd_status "${1:-}"
    ;;
  load)
    shift
    cmd_load "${1:-}" "${2:-}"
    ;;
  -h|--help|"") usage ;;
  *)
    echo "unknown command: $1" >&2
    usage
    exit 1
    ;;
esac
