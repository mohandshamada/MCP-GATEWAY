#!/bin/bash
#
# Generate SSE link with OAuth token
# Usage: ./scripts/generate-oauth-link.sh [domain]
#
# Examples:
#   ./scripts/generate-oauth-link.sh                    # Uses localhost:3000
#   ./scripts/generate-oauth-link.sh mcp.example.com    # Uses https://mcp.example.com
#

set -e

# Get script directory and project root
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

# Try to get domain from config file first
CONFIG_DOMAIN=$(jq -r '.domain.domain // empty' "$CONFIG_FILE" 2>/dev/null)
CONFIG_PUBLIC_URL=$(jq -r '.domain.publicUrl // empty' "$CONFIG_FILE" 2>/dev/null)
GATEWAY_PORT=$(jq -r '.gateway.port // 3000' "$CONFIG_FILE" 2>/dev/null)

# Local URL for API calls (always use localhost)
LOCAL_URL="http://localhost:${GATEWAY_PORT}"

# Domain priority: 1) command line arg, 2) config publicUrl, 3) config domain, 4) localhost
if [ -n "$1" ]; then
    DOMAIN="$1"
    if [[ "$DOMAIN" == "localhost"* ]] || [[ "$DOMAIN" == "127.0.0.1"* ]]; then
        PUBLIC_URL="http://${DOMAIN}"
    else
        PUBLIC_URL="https://${DOMAIN}"
    fi
elif [ -n "$CONFIG_PUBLIC_URL" ] && [ "$CONFIG_PUBLIC_URL" != "null" ]; then
    PUBLIC_URL="$CONFIG_PUBLIC_URL"
    DOMAIN=$(echo "$PUBLIC_URL" | sed 's|https://||' | sed 's|http://||')
elif [ -n "$CONFIG_DOMAIN" ] && [ "$CONFIG_DOMAIN" != "null" ]; then
    DOMAIN="$CONFIG_DOMAIN"
    PUBLIC_URL="https://${DOMAIN}"
else
    DOMAIN="localhost:${GATEWAY_PORT}"
    PUBLIC_URL="http://${DOMAIN}"
fi

# BASE_URL for display purposes (public URL)
BASE_URL="$PUBLIC_URL"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   MCP Gateway OAuth Link Generator${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Check if config exists and read OAuth client credentials
if [ -f "$CONFIG_FILE" ]; then
    CLIENT_ID=$(jq -r '.oauthServer.clients[0].clientId // empty' "$CONFIG_FILE" 2>/dev/null)
    CLIENT_SECRET=$(jq -r '.oauthServer.clients[0].clientSecret // empty' "$CONFIG_FILE" 2>/dev/null)
    OAUTH_ENABLED=$(jq -r '.oauthServer.enabled // false' "$CONFIG_FILE" 2>/dev/null)
else
    echo -e "${RED}Error: Config file not found at $CONFIG_FILE${NC}"
    exit 1
fi

# Check if OAuth server is enabled
if [ "$OAUTH_ENABLED" != "true" ]; then
    echo -e "${YELLOW}Warning: OAuth server is not enabled in config${NC}"
    echo -e "Enable it by setting oauthServer.enabled = true in gateway.json"
    echo ""
fi

# Check if we have credentials
if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
    echo -e "${RED}Error: OAuth client credentials not found in config${NC}"
    echo -e "Make sure oauthServer.clients is configured in gateway.json"
    exit 1
fi

echo -e "${BLUE}Domain:${NC} $DOMAIN"
echo -e "${BLUE}Base URL:${NC} $BASE_URL"
echo -e "${BLUE}Client ID:${NC} $CLIENT_ID"
echo ""

# Request OAuth token (use local URL for API call)
echo -e "${YELLOW}Requesting OAuth token from ${LOCAL_URL}...${NC}"

TOKEN_RESPONSE=$(curl -s -X POST "${LOCAL_URL}/oauth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" 2>/dev/null)

# Check for errors
if echo "$TOKEN_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    ERROR=$(echo "$TOKEN_RESPONSE" | jq -r '.error')
    ERROR_DESC=$(echo "$TOKEN_RESPONSE" | jq -r '.error_description // empty')
    echo -e "${RED}Error getting token: $ERROR${NC}"
    [ -n "$ERROR_DESC" ] && echo -e "${RED}$ERROR_DESC${NC}"
    exit 1
fi

# Extract token
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
EXPIRES_IN=$(echo "$TOKEN_RESPONSE" | jq -r '.expires_in // 3600')
SCOPE=$(echo "$TOKEN_RESPONSE" | jq -r '.scope // empty')

if [ -z "$ACCESS_TOKEN" ]; then
    echo -e "${RED}Error: Failed to get access token${NC}"
    echo -e "${RED}Response: $TOKEN_RESPONSE${NC}"
    exit 1
fi

echo -e "${GREEN}Token obtained successfully!${NC}"
echo ""

# Generate the SSE URL
SSE_URL="${BASE_URL}/sse"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   Generated Links & Configuration${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

echo -e "${GREEN}OAuth Token:${NC}"
echo -e "$ACCESS_TOKEN"
echo ""

echo -e "${GREEN}Token expires in:${NC} ${EXPIRES_IN} seconds"
echo -e "${GREEN}Scopes:${NC} ${SCOPE}"
echo ""

echo -e "${GREEN}SSE Endpoint URL:${NC}"
echo -e "${SSE_URL}"
echo ""

echo -e "${GREEN}Full SSE URL with token (query parameter):${NC}"
echo -e "${SSE_URL}?token=${ACCESS_TOKEN}"
echo ""

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   Claude Desktop Configuration${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

cat << EOF
{
  "mcpServers": {
    "mcp-gateway": {
      "url": "${SSE_URL}",
      "transport": "sse",
      "headers": {
        "Authorization": "Bearer ${ACCESS_TOKEN}"
      }
    }
  }
}
EOF

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   Test Commands${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

echo -e "${YELLOW}Test SSE connection:${NC}"
echo "curl -N -H \"Authorization: Bearer ${ACCESS_TOKEN}\" ${SSE_URL}"
echo ""

echo -e "${YELLOW}Test health endpoint:${NC}"
echo "curl -H \"Authorization: Bearer ${ACCESS_TOKEN}\" ${BASE_URL}/admin/health"
echo ""

echo -e "${YELLOW}Get new token:${NC}"
echo "curl -X POST ${BASE_URL}/oauth/token -d \"grant_type=client_credentials\" -d \"client_id=${CLIENT_ID}\" -d \"client_secret=${CLIENT_SECRET}\""
echo ""

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   OAuth Credentials (save these!)${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "${BLUE}OAuth Token URL:${NC} ${BASE_URL}/oauth/token"
echo -e "${BLUE}Client ID:${NC} ${CLIENT_ID}"
echo -e "${BLUE}Client Secret:${NC} ${CLIENT_SECRET}"
echo -e "${BLUE}Grant Type:${NC} client_credentials"
echo ""

# Save to file
OUTPUT_FILE="$PROJECT_DIR/client-configs/oauth-sse-config.txt"
mkdir -p "$PROJECT_DIR/client-configs"

cat > "$OUTPUT_FILE" << EOF
# MCP Gateway OAuth SSE Configuration
# Generated: $(date)
# Domain: ${DOMAIN}

## OAuth Credentials
OAuth Token URL: ${BASE_URL}/oauth/token
Client ID: ${CLIENT_ID}
Client Secret: ${CLIENT_SECRET}
Grant Type: client_credentials

## Current Token (expires in ${EXPIRES_IN}s)
Access Token: ${ACCESS_TOKEN}

## SSE Endpoint
SSE URL: ${SSE_URL}
SSE URL with token: ${SSE_URL}?token=${ACCESS_TOKEN}

## Claude Desktop Configuration
${SSE_URL}

Headers:
  Authorization: Bearer ${ACCESS_TOKEN}

## Get New Token Command
curl -X POST ${BASE_URL}/oauth/token \\
  -d "grant_type=client_credentials" \\
  -d "client_id=${CLIENT_ID}" \\
  -d "client_secret=${CLIENT_SECRET}"
EOF

echo -e "${GREEN}Configuration saved to:${NC} $OUTPUT_FILE"
echo ""
