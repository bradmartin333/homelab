#!/bin/bash
# vikunja-add-user.sh — TUI for provisioning Vikunja accounts with random initial passwords
#
# Registration is closed after README.md Phase 13.4, so this is how you hand out
# new accounts afterward: it runs `vikunja user create` inside the container and
# generates a random one-time password per user instead of a shared default.
#
# Usage:
#   scripts/vikunja-add-user.sh
#
# Override the container name with VIKUNJA_CONTAINER (default: vikunja).

set -uo pipefail

# --- Configuration ---
VIKUNJA_CONTAINER="${VIKUNJA_CONTAINER:-vikunja}"
VIKUNJA_BINARY="/app/vikunja/vikunja"

# UI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

clear
echo -e "${BOLD}======================================${NC}"
echo -e "${BOLD}    Vikunja Team Onboarding TUI       ${NC}"
echo -e "${BOLD}======================================${NC}"

# Check if the Vikunja container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${VIKUNJA_CONTAINER}$"; then
    echo -e "${RED}Error: Container '${VIKUNJA_CONTAINER}' is not running.${NC}"
    exit 1
fi

# username -> "email password" for the closing summary
declare -a CREATED_SUMMARY=()

while true; do
    echo -e "\n${BOLD}--- Create New Account ---${NC}"

    read -r -p "Username        : " USERNAME
    read -r -p "Email           : " EMAIL

    if [[ -z "$USERNAME" || -z "$EMAIL" ]]; then
        echo -e "${RED}Username and Email are required. Restarting entry...${NC}"
        continue
    fi

    # Random 16-char password, alnum only so it's easy to read aloud/type.
    PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)

    echo -e "\nProvisioning user ${BOLD}${USERNAME}${NC}..."

    docker exec -i "$VIKUNJA_CONTAINER" "$VIKUNJA_BINARY" user create \
        --username "$USERNAME" \
        --email "$EMAIL" \
        --password "$PASSWORD"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SUCCESS:${NC} Account for $USERNAME is ready."
        echo -e "${YELLOW}Initial password: ${PASSWORD}${NC} (share this out-of-band; it is not stored anywhere)"
        CREATED_SUMMARY+=("$USERNAME | $EMAIL | $PASSWORD")
    else
        echo -e "${RED}FAILURE:${NC} Could not create user. Check if username/email is taken."
    fi

    echo -e "--------------------------------------"
    read -r -p "Add another user? (y/n): " AGAIN
    [[ "$AGAIN" != "y" ]] && break
done

echo -e "\n${BOLD}Done!${NC} Remember to add these users to your shared team via the Web UI."

if [ "${#CREATED_SUMMARY[@]}" -gt 0 ]; then
    echo -e "\n${BOLD}--- New Accounts (initial credentials, tell users to change on first login) ---${NC}"
    printf '%s\n' "${CREATED_SUMMARY[@]}"
fi

# Print out the current user list
echo -e "\n${BOLD}--- Current Vikunja Users ---${NC}"
docker exec -i "$VIKUNJA_CONTAINER" "$VIKUNJA_BINARY" user list
