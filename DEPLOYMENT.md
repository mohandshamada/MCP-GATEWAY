# Deployment Guide

## Prerequisites

- Ubuntu 20.04 or later
- 2GB RAM minimum (8GB recommended)
- Node.js 18+ and npm
- sudo access

## Quick Deploy
```bash
# Clone repository
git clone https://github.com/mohandshamada/MCP-GATEWAY.git
cd MCP-GATEWAY

# Set environment variables
export DOMAIN="mcp.example.com"
export EMAIL="admin@example.com"

# Run setup scripts
bash scripts/setup-ubuntu.sh      # System dependencies
bash scripts/setup-caddy.sh       # Caddy reverse proxy
bash scripts/setup-gateway.sh     # MCP Gateway service

# Verify deployment
TOKEN="your-token-here"
curl -s https://mcp.example.com/admin/health \
  -H "Authorization: Bearer $TOKEN" | jq .
```

## Service Management
```bash
# Check status
systemctl status mcp-gateway.service
systemctl status caddy.service

# View logs
journalctl -u mcp-gateway -f
journalctl -u caddy -f

# Restart
systemctl restart mcp-gateway.service
systemctl restart caddy.service
```

## Troubleshooting

See `docs/TROUBLESHOOTING.md` for common issues.
