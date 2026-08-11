#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$REPO_DIR/systemd"

shopt -s nullglob
services=("$UNIT_DIR"/*.service)
timers=("$UNIT_DIR"/*.timer)
shopt -u nullglob

if [ "${#services[@]}" -eq 0 ] && [ "${#timers[@]}" -eq 0 ]; then
  echo "error: no unit files found in $UNIT_DIR" >&2
  exit 1
fi

for unit in "${services[@]}" "${timers[@]}"; do
  sudo ln -sf "$unit" "/etc/systemd/system/$(basename "$unit")"
done

sudo systemctl daemon-reload

# Timers: enable + restart unconditionally. `enable --now` only starts a timer
# that isn't already active — if it's already active (e.g. reinstalling this
# script), that's a no-op and it won't recompute NextElapseUSecRealtime.
# restart forces it every time, which is what actually un-wedges it.
for unit in "${timers[@]}"; do
  name=$(basename "$unit")
  sudo systemctl enable "$name"
  sudo systemctl restart "$name"
done

echo "installed:"
systemctl list-timers | grep -F "$(for t in "${timers[@]}"; do basename "$t"; done | paste -sd'|')" || true
