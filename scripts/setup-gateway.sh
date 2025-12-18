#!/bin/bash
set -e

echo "Setting up MCP Gateway..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Project directory: $PROJECT_DIR"

# Install dependencies
cd "$PROJECT_DIR"
npm install

# Build project
npm run build

# Ensure config directory exists
mkdir -p "$PROJECT_DIR/config"

# Create default config if not exists
if [ ! -f "$PROJECT_DIR/config/gateway.json" ]; then
    echo "Creating gateway.json from example..."
    cp "$PROJECT_DIR/config/gateway.example.json" "$PROJECT_DIR/config/gateway.json"
    echo "Please edit gateway.json with your configuration"
fi

# Verify gateway.json is valid JSON
if ! jq . "$PROJECT_DIR/config/gateway.json" &>/dev/null; then
    echo "ERROR: gateway.json is not valid JSON!"
    exit 1
fi

# Check if systemd is available
if command -v systemctl &> /dev/null && [ -d /run/systemd/system ]; then
    # Create systemd service
    echo "Creating systemd service..."
    cat > /etc/systemd/system/mcp-gateway.service << EOF
[Unit]
Description=MCP Gateway Service
After=network.target
Documentation=https://github.com/mohandshamada/MCP-GATEWAY

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

[Install]
WantedBy=multi-user.target
EOF

    # Enable service for auto-start
    systemctl daemon-reload
    systemctl enable mcp-gateway.service

    # Start the service
    echo "Starting MCP Gateway..."
    systemctl start mcp-gateway.service
    sleep 3

    # Verify it's running
    if systemctl is-active --quiet mcp-gateway.service; then
        echo "MCP Gateway started successfully"
        echo ""
        echo "Useful commands:"
        echo "  systemctl status mcp-gateway    - Check status"
        echo "  systemctl restart mcp-gateway   - Restart service"
        echo "  journalctl -u mcp-gateway -f    - View logs"
    else
        echo "MCP Gateway failed to start"
        journalctl -u mcp-gateway -n 20 --no-pager
        exit 1
    fi
else
    # No systemd - create a start script instead
    echo "systemd not available, creating start script..."

    cat > "$PROJECT_DIR/start-gateway.sh" << EOF
#!/bin/bash
cd "$PROJECT_DIR"
node dist/index.js
EOF
    chmod +x "$PROJECT_DIR/start-gateway.sh"

    echo ""
    echo "MCP Gateway setup complete!"
    echo ""
    echo "To start the gateway, run:"
    echo "  $PROJECT_DIR/start-gateway.sh"
    echo ""
    echo "Or run in background:"
    echo "  nohup $PROJECT_DIR/start-gateway.sh > $PROJECT_DIR/logs/gateway.log 2>&1 &"
fi

echo ""
echo "Gateway configuration: $PROJECT_DIR/config/gateway.json"
echo ""
