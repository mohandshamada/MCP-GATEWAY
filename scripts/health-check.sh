#!/bin/bash

# Health check script for MCP Gateway
# Reads token from config file automatically

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/gateway.json"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found at $CONFIG_FILE"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not installed"
    echo "Install with: apt-get install -y jq"
    exit 1
fi

# Read token from config file (first token in the array)
TOKEN=$(jq -r '.auth.tokens[0] // empty' "$CONFIG_FILE")

if [ -z "$TOKEN" ]; then
    echo "ERROR: No auth token found in config file"
    echo "Please add a token to auth.tokens array in $CONFIG_FILE"
    exit 1
fi

# Domain can be passed as argument or read from config
DOMAIN="${1:-$(jq -r '.domain.domain // "localhost"' "$CONFIG_FILE")}"

echo "Checking MCP Gateway health on $DOMAIN..."
echo ""

# Test direct connection
echo "1. Testing localhost connection..."
HEALTH=$(curl -s http://localhost:3000/admin/health \
  -H "Authorization: Bearer $TOKEN" | jq -r '.status // "error"')
echo "   Health: $HEALTH"

# Test HTTPS via Caddy (only if domain is not localhost)
if [ "$DOMAIN" != "localhost" ]; then
    echo "2. Testing HTTPS via Caddy..."
    HEALTH_HTTPS=$(curl -s "https://$DOMAIN/admin/health" \
      -H "Authorization: Bearer $TOKEN" | jq -r '.status // "error"')
    echo "   Health: $HEALTH_HTTPS"
else
    HEALTH_HTTPS="skipped"
    echo "2. HTTPS test skipped (localhost)"
fi

# Test server list
echo "3. Checking server status..."
curl -s http://localhost:3000/admin/status \
  -H "Authorization: Bearer $TOKEN" | \
  jq -r '.data.registry.servers[] | "   \(.id): \(.health)"' 2>/dev/null || echo "   Unable to retrieve server status"

echo ""

# Summary
if [ "$HEALTH" = "healthy" ]; then
    if [ "$HEALTH_HTTPS" = "healthy" ] || [ "$HEALTH_HTTPS" = "skipped" ]; then
        echo "All checks passed"
        exit 0
    fi
fi

echo "Health checks failed"
exit 1
