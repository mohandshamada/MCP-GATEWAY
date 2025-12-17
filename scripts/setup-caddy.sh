#!/bin/bash
set -e

echo "Setting up Caddy reverse proxy..."

# Create caddy user if doesn't exist
if ! id caddy &>/dev/null; then
    echo "Creating caddy system user..."
    useradd --system --home /var/lib/caddy --shell /bin/false caddy
fi

# Install Caddy if not present
if ! command -v caddy &>/dev/null; then
    echo "Installing Caddy..."
    apt-get update
    apt-get install -y caddy
fi

# Create and fix log directory
echo "Setting up log directory..."
mkdir -p /var/log/caddy
rm -f /var/log/caddy/mcp-gateway.log  # Remove if exists with wrong ownership
chown caddy:caddy /var/log/caddy
chmod 755 /var/log/caddy

# Create ACME storage directories
echo "Setting up ACME storage..."
mkdir -p /var/lib/caddy/.local/share/caddy
chown -R caddy:caddy /var/lib/caddy
chmod -R 750 /var/lib/caddy

# Validate and install Caddyfile
echo "Installing Caddyfile..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "${SCRIPT_DIR}/Caddyfile.template" /etc/caddy/Caddyfile
sed -i "s/DOMAIN/${DOMAIN:-mcp.mshousha.uk}/g" /etc/caddy/Caddyfile
sed -i "s/EMAIL/${EMAIL:-admin@example.com}/g" /etc/caddy/Caddyfile

# Validate syntax
if ! /usr/bin/caddy validate --config /etc/caddy/Caddyfile; then
    echo "ERROR: Caddyfile validation failed!"
    exit 1
fi

# Enable and start service
systemctl daemon-reload
systemctl enable caddy.service
systemctl start caddy.service

echo "Caddy setup complete"
systemctl status caddy.service
