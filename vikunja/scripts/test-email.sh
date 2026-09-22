#!/bin/bash
# test-email.sh — simple CLI script to test email sending from the Vikunja container
#
#
# Usage:
#   scripts/test-email.sh <email-address>
#
# Override the container name with VIKUNJA_CONTAINER (default: vikunja).

set -uo pipefail

# --- Configuration ---
VIKUNJA_CONTAINER="${VIKUNJA_CONTAINER:-vikunja}"
VIKUNJA_BINARY="/app/vikunja/vikunja"
TEST_EMAIL="${1:-}"

# UI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

if [ -z "$TEST_EMAIL" ]; then
    echo "Usage: $0 <email-address>"
    exit 1
fi

# Check if the Vikunja container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${VIKUNJA_CONTAINER}$"; then
    echo -e "${RED}Error: Container '${VIKUNJA_CONTAINER}' is not running.${NC}"
    exit 1
fi

docker exec -i "$VIKUNJA_CONTAINER" "$VIKUNJA_BINARY" testmail "$TEST_EMAIL"
