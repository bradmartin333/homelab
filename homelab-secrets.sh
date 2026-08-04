#!/usr/bin/env bash
# homelab-secrets.sh — encrypt/decrypt sops secrets and commit/push /opt/homelab
#
# Drop this on the homelab box (e.g. /opt/homelab/scripts/homelab-secrets.sh)
# and run it from there.
#
# Usage:
#   homelab-secrets.sh commit ["message"]   Re-encrypt changed .env files, then commit and push
#   homelab-secrets.sh encrypt              Re-encrypt all */.env -> */.env.enc, no git actions
#   homelab-secrets.sh decrypt              Decrypt all */.env.enc -> */.env (chmod 600)
#
# Override the repo location with HOMELAB_DIR (default: /opt/homelab).

set -euo pipefail

REPO_DIR="${HOMELAB_DIR:-/opt/homelab}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  commit ["message"]   Re-encrypt any changed .env files, then git add -A, commit, and push.
                        Default message: "update encrypted secrets"
  encrypt               Re-encrypt all */.env -> */.env.enc, no git actions
  decrypt               Decrypt all */.env.enc -> */.env (chmod 600)

Repo location: $REPO_DIR (override with HOMELAB_DIR=/path/to/repo)
EOF
}

require_repo() {
  [ -d "$REPO_DIR/.git" ] || {
    echo "error: $REPO_DIR is not a git repo (set HOMELAB_DIR to override)" >&2
    exit 1
  }
  command -v sops >/dev/null || { echo "error: sops not installed" >&2; exit 1; }
}

encrypt_secrets() {
  cd "$REPO_DIR"
  local found=0
  for f in */.env; do
    [ -f "$f" ] || continue
    found=1
    sops -e --input-type dotenv --output-type dotenv "$f" > "$f.enc"
    echo "encrypted: $f -> $f.enc"
  done
  [ "$found" -eq 1 ] || echo "no */.env files found, nothing to encrypt"
}

decrypt_secrets() {
  cd "$REPO_DIR"
  local found=0
  for f in */.env.enc; do
    [ -f "$f" ] || continue
    found=1
    sops -d --input-type dotenv --output-type dotenv "$f" > "${f%.enc}"
    chmod 600 "${f%.enc}"
    echo "decrypted: $f -> ${f%.enc}"
  done
  [ "$found" -eq 1 ] || echo "no */.env.enc files found, nothing to decrypt"
}

cmd_commit() {
  cd "$REPO_DIR"
  local msg="${1:-}"
  [ -n "$msg" ] || msg="update encrypted secrets"

  encrypt_secrets

  git add -A

  # Refuse to push a plaintext .env even if it slipped past encrypt_secrets.
  if git diff --cached --name-only | grep -qE '(^|/)\.env$'; then
    echo "error: refusing to commit — a plaintext .env file is staged:" >&2
    git diff --cached --name-only | grep -E '(^|/)\.env$' >&2
    exit 1
  fi

  if git diff --cached --quiet; then
    echo "nothing to commit"
    return 0
  fi

  git commit -m "$msg"
  git push
}

require_repo

case "${1:-}" in
  commit)
    shift
    cmd_commit "${1:-}"
    ;;
  encrypt) encrypt_secrets ;;
  decrypt) decrypt_secrets ;;
  -h|--help|"") usage ;;
  *)
    echo "unknown command: $1" >&2
    usage
    exit 1
    ;;
esac
