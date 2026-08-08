#!/bin/bash
# test-email.sh — simple CLI script to test email sending from the Vikunja container
#
#
# Usage:
#   scripts/test-email.sh
#
# Override the container name with VIKUNJA_CONTAINER (default: vikunja).

set -uo pipefail

# --- Configuration ---
VIKUNJA_CONTAINER="${VIKUNJA_CONTAINER:-vikunja}"
VIKUNJA_BINARY="/app/vikunja/vikunja"

# Check if the Vikunja container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${VIKUNJA_CONTAINER}$"; then
    echo -e "${RED}Error: Container '${VIKUNJA_CONTAINER}' is not running.${NC}"
    exit 1
fi

docker exec -i "$VIKUNJA_CONTAINER" "$VIKUNJA_BINARY" testemail
