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
#   bot-ctl.sh status <container>            Show the profile currently active on a container
#   bot-ctl.sh load <container> <profile>    Hot-swap a running container onto a profile
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
  status <container>            Show the profile currently active on a container
  load <container> <profile>    Copy the profile in and hot-reload the container

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

cmd_status() {
  local container="${1:?usage: $(basename "$0") status <container>}"
  local active="$BOTS_DIR/active/$container.env"
  if [ ! -f "$active" ]; then
    echo "no profile loaded for '$container' (running on .env defaults)"
    return 0
  fi
  head -n 1 "$active" | sed 's/^# //'
}

cmd_load() {
  local container="${1:?usage: $(basename "$0") load <container> <profile>}"
  local profile="${2:?usage: $(basename "$0") load <container> <profile>}"
  local src="$BOTS_DIR/$profile.env"
  local active="$BOTS_DIR/active/$container.env"

  [ -f "$src" ] || { echo "error: no such profile: $profile ($src)" >&2; exit 1; }

  local running
  running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null) || {
    echo "error: no such container: $container" >&2
    exit 1
  }
  [ "$running" = "true" ] || { echo "error: container '$container' is not running" >&2; exit 1; }

  mkdir -p "$BOTS_DIR/active"
  {
    echo "# profile: $profile (loaded $(date -u +%Y-%m-%dT%H:%M:%SZ) by bot-ctl.sh)"
    cat "$src"
  } > "$active.tmp"
  mv "$active.tmp" "$active"

  docker kill -s HUP "$container" >/dev/null
  echo "loaded '$profile' onto '$container'"
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
