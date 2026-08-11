#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for unit in "$REPO_DIR"/systemd/*.service "$REPO_DIR"/systemd/*.timer; do
  sudo ln -sf "$unit" "/etc/systemd/system/$(basename "$unit")"
done
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-backup.timer
