#!/bin/bash

# Generate authentication token and output ready-to-use links
# Usage: ./scripts/generate-token.sh [domain]
# Example: ./scripts/generate-token.sh mcp.example.com

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/gateway.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get domain from argument or config
DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
    # Try to get domain from config
    if command -v jq &> /dev/null && [ -f "$CONFIG_FILE" ]; then
        DOMAIN=$(jq -r '.domain.domain // .domain.publicUrl // empty' "$CONFIG_FILE" 2>/dev/null | sed 's|https://||' | sed 's|http://||' | sed 's|/.*||')
    fi
fi

# Get port from config
PORT="3000"
if command -v jq &> /dev/null && [ -f "$CONFIG_FILE" ]; then
    PORT=$(jq -r '.gateway.port // 3000' "$CONFIG_FILE" 2>/dev/null)
fi

# Generate a secure random token
NEW_TOKEN=$(openssl rand -hex 32)

echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}       MCP Gateway Token Generator${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found at $CONFIG_FILE${NC}"
    exit 1
fi

# Check if jq is available for JSON manipulation
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Warning: jq not installed. Token will be displayed but not auto-added to config.${NC}"
    echo -e "${YELLOW}Install with: apt-get install jq${NC}"
    echo ""
    echo -e "${GREEN}Generated Token:${NC}"
    echo -e "${YELLOW}$NEW_TOKEN${NC}"
    echo ""
    echo -e "${BLUE}Add this token manually to config/gateway.json in the auth.tokens array${NC}"
else
    # Add token to config using jq
    TEMP_FILE=$(mktemp)
    jq --arg token "$NEW_TOKEN" '.auth.tokens += [$token]' "$CONFIG_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$CONFIG_FILE"

    echo -e "${GREEN}New token generated and added to config!${NC}"
fi

echo ""
echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}              CONNECTION DETAILS${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""
echo -e "${GREEN}Token:${NC}"
echo "$NEW_TOKEN"
echo ""

# Output URLs
echo -e "${GREEN}SSE Endpoints:${NC}"
echo ""

# Local URL
echo -e "${BLUE}Local:${NC}"
echo "  http://localhost:$PORT/sse?token=$NEW_TOKEN"
echo ""

# Domain URL if provided
if [ -n "$DOMAIN" ]; then
    echo -e "${BLUE}Public (HTTPS):${NC}"
    echo "  https://$DOMAIN/sse?token=$NEW_TOKEN"
    echo ""
    echo -e "${BLUE}Public (HTTP):${NC}"
    echo "  http://$DOMAIN/sse?token=$NEW_TOKEN"
    echo ""
fi

echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}           CLAUDE DESKTOP CONFIG${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""

if [ -n "$DOMAIN" ]; then
    BASE_URL="https://$DOMAIN"
else
    BASE_URL="http://localhost:$PORT"
fi

cat << EOF
{
  "mcpServers": {
    "mcp-gateway": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "${BASE_URL}/sse?token=${NEW_TOKEN}"
      ]
    }
  }
}
EOF

echo ""
echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}              CURL TEST COMMAND${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""
echo -e "${BLUE}Test with:${NC}"
echo "curl -H \"Authorization: Bearer $NEW_TOKEN\" ${BASE_URL}/sse"
echo ""
echo -e "${YELLOW}Note: Restart the gateway if hot-reload is disabled${NC}"
echo ""
