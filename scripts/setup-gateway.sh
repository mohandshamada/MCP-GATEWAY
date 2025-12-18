#!/bin/bash

# MCP Gateway Setup Script
# Installs dependencies, builds project, configures services
# Incorporates lessons learned from production deployments

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Setting up MCP Gateway...${NC}"
echo ""

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Project directory: $PROJECT_DIR"
echo ""

# Change to project directory
cd "$PROJECT_DIR"

# Step 1: Check prerequisites
echo -e "${BLUE}Step 1: Checking prerequisites...${NC}"

# Check Node.js version
if ! command -v node &>/dev/null; then
    echo -e "${RED}ERROR: Node.js is not installed${NC}"
    echo "Install with: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs"
    exit 1
fi

NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
if [ "$NODE_VERSION" -lt 18 ]; then
    echo -e "${RED}ERROR: Node.js 18+ required (found: $(node -v))${NC}"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} Node.js $(node -v)"

# Check npm
if ! command -v npm &>/dev/null; then
    echo -e "${RED}ERROR: npm is not installed${NC}"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} npm $(npm -v)"

# Check jq (required for config validation)
if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}[WARN]${NC} jq is not installed - installing..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y jq
    else
        echo -e "${RED}ERROR: Please install jq manually${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}[OK]${NC} jq installed"

# Step 2: Install dependencies
echo ""
echo -e "${BLUE}Step 2: Installing dependencies...${NC}"
npm install

# Step 3: Build project
echo ""
echo -e "${BLUE}Step 3: Building project...${NC}"
npm run build

# Step 4: Configuration validation
echo ""
echo -e "${BLUE}Step 4: Validating configuration...${NC}"

# Ensure config directory exists
mkdir -p "$PROJECT_DIR/config"

# Create default config if not exists
if [ ! -f "$PROJECT_DIR/config/gateway.json" ]; then
    echo "Creating gateway.json from example..."
    if [ -f "$PROJECT_DIR/config/gateway.example.json" ]; then
        cp "$PROJECT_DIR/config/gateway.example.json" "$PROJECT_DIR/config/gateway.json"
        echo -e "${YELLOW}[WARN]${NC} Default configuration created"
        echo "Please edit config/gateway.json with your settings"
        echo ""
    else
        echo -e "${RED}ERROR: No example config found${NC}"
        exit 1
    fi
fi

# Validate JSON syntax
if ! jq . "$PROJECT_DIR/config/gateway.json" &>/dev/null; then
    echo -e "${RED}ERROR: gateway.json is not valid JSON!${NC}"
    echo ""
    echo "Attempting to find the error..."
    python3 -c "import json; json.load(open('$PROJECT_DIR/config/gateway.json'))" 2>&1 || true
    exit 1
fi
echo -e "${GREEN}[OK]${NC} JSON syntax valid"

# Validate required fields
GATEWAY_PORT=$(jq -r '.gateway.port // empty' "$PROJECT_DIR/config/gateway.json")
if [ -z "$GATEWAY_PORT" ]; then
    echo -e "${RED}ERROR: Missing gateway.port in configuration${NC}"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} Gateway port: $GATEWAY_PORT"

# Check auth tokens
TOKEN_COUNT=$(jq -r '.auth.tokens | length' "$PROJECT_DIR/config/gateway.json")
if [ "$TOKEN_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}[WARN]${NC} No authentication tokens configured"
    echo "Run ./scripts/generate-token.sh to create one"
else
    echo -e "${GREEN}[OK]${NC} Auth tokens: $TOKEN_COUNT configured"
fi

# Check servers
SERVER_COUNT=$(jq -r '.servers | length' "$PROJECT_DIR/config/gateway.json")
ENABLED_COUNT=$(jq -r '[.servers[] | select(.enabled == true)] | length' "$PROJECT_DIR/config/gateway.json")
echo -e "${GREEN}[OK]${NC} MCP servers: $ENABLED_COUNT enabled (of $SERVER_COUNT configured)"

# Ensure logs directory exists
mkdir -p "$PROJECT_DIR/logs"

# Step 5: Service setup
echo ""
echo -e "${BLUE}Step 5: Setting up service...${NC}"

# Check if systemd is available
if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
    echo "Systemd detected - creating service..."

    # Create systemd service file
    cat > /etc/systemd/system/mcp-gateway.service << EOF
[Unit]
Description=MCP Gateway Service
Documentation=https://github.com/mohandshamada/MCP-GATEWAY
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/node $PROJECT_DIR/dist/index.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mcp-gateway
Environment="NODE_ENV=production"

# Security hardening (optional - uncomment if needed)
# NoNewPrivileges=true
# ProtectSystem=strict
# ProtectHome=read-only
# ReadWritePaths=$PROJECT_DIR/logs $PROJECT_DIR/mcp-data

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${GREEN}[OK]${NC} Service file created"

    # Reload systemd
    systemctl daemon-reload

    # CRITICAL: Enable service for auto-start (lesson learned!)
    systemctl enable mcp-gateway.service
    echo -e "${GREEN}[OK]${NC} Service enabled for auto-start"

    # Start the service
    echo "Starting MCP Gateway..."
    systemctl start mcp-gateway.service
    sleep 3

    # Verify it's running
    if systemctl is-active --quiet mcp-gateway.service; then
        echo -e "${GREEN}[OK]${NC} MCP Gateway started successfully"

        # Post-start verification
        echo ""
        echo -e "${BLUE}Step 6: Post-start verification...${NC}"

        # Wait for gateway to initialize
        sleep 2

        # Test health endpoint
        TOKEN=$(jq -r '.auth.tokens[0] // "test"' "$PROJECT_DIR/config/gateway.json")
        HEALTH=$(curl -s --max-time 5 "http://localhost:$GATEWAY_PORT/admin/health" \
            -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.status // "unknown"' 2>/dev/null || echo "unreachable")

        if [ "$HEALTH" = "healthy" ]; then
            echo -e "${GREEN}[OK]${NC} Health check passed"
        else
            echo -e "${YELLOW}[WARN]${NC} Health check returned: $HEALTH"
        fi

        # Test tool enumeration
        TOOL_COUNT=$(curl -s --max-time 30 -X POST "http://localhost:$GATEWAY_PORT/message" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}' 2>/dev/null | \
            python3 -c "import sys, json; d=json.load(sys.stdin); print(len(d.get('result', {}).get('tools', [])))" 2>/dev/null || echo "0")

        if [ "$TOOL_COUNT" -gt 0 ]; then
            echo -e "${GREEN}[OK]${NC} Tools available: $TOOL_COUNT"
        else
            echo -e "${YELLOW}[WARN]${NC} No tools enumerated yet (servers may still be starting)"
        fi

        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}MCP Gateway setup complete!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        echo "Useful commands:"
        echo "  systemctl status mcp-gateway    - Check status"
        echo "  systemctl restart mcp-gateway   - Restart service"
        echo "  journalctl -u mcp-gateway -f    - View logs"
        echo ""
        echo "Validation:"
        echo "  ./scripts/validate-installation.sh  - Run full validation"
        echo "  ./scripts/health-check.sh           - Quick health check"
    else
        echo -e "${RED}MCP Gateway failed to start${NC}"
        echo ""
        echo "Recent logs:"
        journalctl -u mcp-gateway -n 30 --no-pager
        exit 1
    fi
else
    # No systemd - create a start script instead
    echo "systemd not available, creating start script..."

    cat > "$PROJECT_DIR/start-gateway.sh" << EOF
#!/bin/bash
cd "$PROJECT_DIR"
export NODE_ENV=production
node dist/index.js
EOF
    chmod +x "$PROJECT_DIR/start-gateway.sh"

    echo -e "${GREEN}[OK]${NC} Start script created"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}MCP Gateway setup complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "To start the gateway, run:"
    echo "  $PROJECT_DIR/start-gateway.sh"
    echo ""
    echo "Or run in background:"
    echo "  nohup $PROJECT_DIR/start-gateway.sh > $PROJECT_DIR/logs/gateway.log 2>&1 &"
    echo ""
    echo "To run with process manager (recommended):"
    echo "  npm install -g pm2"
    echo "  pm2 start $PROJECT_DIR/dist/index.js --name mcp-gateway"
    echo "  pm2 startup  # Enable auto-start"
    echo "  pm2 save"
fi

echo "Gateway configuration: $PROJECT_DIR/config/gateway.json"
echo ""

# Domain setup reminder
DOMAIN=$(jq -r '.domain.domain // empty' "$PROJECT_DIR/config/gateway.json")
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ] && [ "$DOMAIN" != "localhost" ]; then
    echo -e "${BLUE}Domain Configuration:${NC}"
    echo "  Domain: $DOMAIN"
    echo ""
    echo "  Next steps for HTTPS:"
    echo "    1. Run: ./scripts/setup-caddy.sh"
    echo "    2. Ensure DNS A record points to this server"
    echo "    3. Run: ./scripts/validate-installation.sh"
    echo ""
fi
