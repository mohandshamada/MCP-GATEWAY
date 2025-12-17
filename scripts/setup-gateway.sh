#!/bin/bash
set -e

echo "Setting up MCP Gateway..."

# Install dependencies
cd /root/MCP-GATEWAY
npm install

# Build project
npm run build

# Ensure config directory exists
mkdir -p /root/MCP-GATEWAY/config

# Create default config if not exists
if [ ! -f /root/MCP-GATEWAY/config/gateway.json ]; then
    echo "Creating gateway.json from example..."
    cp /root/MCP-GATEWAY/config/gateway.example.json /root/MCP-GATEWAY/config/gateway.json
    echo "Please edit gateway.json with your configuration"
fi

# Verify gateway.json is valid JSON
if ! jq . /root/MCP-GATEWAY/config/gateway.json &>/dev/null; then
    echo "ERROR: gateway.json is not valid JSON!"
    exit 1
fi

# Create systemd service
echo "Creating systemd service..."
cat > /etc/systemd/system/mcp-gateway.service << 'EOF'
[Unit]
Description=MCP Gateway Service
After=network.target caddy.service
Requires=caddy.service
Documentation=https://github.com/mohandshamada/MCP-GATEWAY

[Service]
Type=simple
User=root
WorkingDirectory=/root/MCP-GATEWAY
ExecStart=/usr/bin/npm start
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
else
    echo "MCP Gateway failed to start"
    journalctl -u mcp-gateway -n 20 --no-pager
    exit 1
fi
