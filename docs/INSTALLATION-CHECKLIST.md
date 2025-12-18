# MCP Gateway Installation Checklist

Use this checklist to ensure a complete and successful deployment.

## Pre-Installation

- [ ] **VPS/Server provisioned**
  - Minimum: 2GB RAM, 1 CPU
  - Recommended: 4GB+ RAM, 2+ CPU
  - Ubuntu 20.04+ or similar Linux distribution

- [ ] **Network access configured**
  - SSH access working
  - Ports 80, 443 accessible from internet (for HTTPS)
  - Port 3000 available locally

- [ ] **Domain name ready** (for HTTPS)
  - Domain registered
  - DNS management access available
  - Cloudflare or similar CDN account (optional but recommended)

---

## System Setup

- [ ] **Update system packages**
  ```bash
  sudo apt update && sudo apt upgrade -y
  ```

- [ ] **Install Node.js 18+**
  ```bash
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
  node -v  # Should show v18+ or v20+
  ```

- [ ] **Install required tools**
  ```bash
  sudo apt-get install -y git jq curl
  ```

- [ ] **Clone repository**
  ```bash
  git clone https://github.com/mohandshamada/MCP-GATEWAY.git
  cd MCP-GATEWAY
  ```

---

## Gateway Installation

- [ ] **Install dependencies**
  ```bash
  npm install
  ```

- [ ] **Build project**
  ```bash
  npm run build
  ```

- [ ] **Configure gateway**
  ```bash
  # Copy example config if needed
  cp config/gateway.example.json config/gateway.json

  # Edit configuration
  nano config/gateway.json
  ```

- [ ] **Generate authentication token**
  ```bash
  ./scripts/generate-token.sh
  ```

- [ ] **Run setup script**
  ```bash
  sudo ./scripts/setup-gateway.sh
  ```

---

## HTTPS/Domain Setup (Optional but Recommended)

- [ ] **Configure DNS**
  - Create A record pointing to your VPS IP
  - Wait for propagation (verify with `dig your-domain.com`)

- [ ] **Install Caddy**
  ```bash
  sudo ./scripts/setup-caddy.sh
  ```

- [ ] **Update Caddyfile**
  - Replace `DOMAIN` with your domain
  - Replace `EMAIL` with your email
  ```bash
  sudo nano /etc/caddy/Caddyfile
  ```

- [ ] **Verify Caddy configuration**
  ```bash
  sudo caddy validate --config /etc/caddy/Caddyfile
  sudo systemctl reload caddy
  ```

---

## Service Configuration

- [ ] **Enable services for auto-start**
  ```bash
  sudo systemctl enable mcp-gateway
  sudo systemctl enable caddy  # if using Caddy
  ```

- [ ] **Verify services are running**
  ```bash
  sudo systemctl status mcp-gateway
  sudo systemctl status caddy
  ```

---

## Verification

- [ ] **Run validation script**
  ```bash
  ./scripts/validate-installation.sh
  ```

- [ ] **Test health endpoint**
  ```bash
  ./scripts/health-check.sh
  ```

- [ ] **Verify tool count**
  ```bash
  TOKEN=$(jq -r '.auth.tokens[0]' config/gateway.json)
  curl -s -X POST http://localhost:3000/message \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
    python3 -c "import sys,json; print(f'{len(json.load(sys.stdin)[\"result\"][\"tools\"])} tools available')"
  ```

- [ ] **Test SSE streaming**
  ```bash
  TOKEN=$(jq -r '.auth.tokens[0]' config/gateway.json)
  timeout 10 curl -s http://localhost:3000/sse \
    -H "Authorization: Bearer $TOKEN" | head -5
  ```

- [ ] **Test HTTPS** (if configured)
  ```bash
  curl -v https://your-domain.com/admin/health \
    -H "Authorization: Bearer $TOKEN"
  ```

---

## Claude Desktop Configuration

- [ ] **Get SSE URL**
  ```bash
  # For localhost (development)
  echo "http://localhost:3000/sse"

  # For production with domain
  echo "https://your-domain.com/sse"
  ```

- [ ] **Configure Claude Desktop**

  Add to Claude Desktop config (`~/.config/claude/config.json` or similar):
  ```json
  {
    "mcpServers": {
      "mcp-gateway": {
        "url": "https://your-domain.com/sse",
        "headers": {
          "Authorization": "Bearer YOUR_TOKEN"
        }
      }
    }
  }
  ```

- [ ] **Restart Claude Desktop**

- [ ] **Verify tools appear in Claude Desktop**

---

## Post-Installation

- [ ] **Set up monitoring** (optional)
  ```bash
  # Simple cron-based health check
  (crontab -l 2>/dev/null; echo "*/5 * * * * /path/to/MCP-GATEWAY/scripts/health-check.sh > /dev/null 2>&1") | crontab -
  ```

- [ ] **Configure log rotation** (if not using systemd journal)
  ```bash
  sudo nano /etc/logrotate.d/mcp-gateway
  ```

- [ ] **Document your configuration**
  - Token location
  - Domain used
  - Custom configurations

- [ ] **Back up configuration**
  ```bash
  cp config/gateway.json config/gateway.json.backup
  ```

---

## Quick Reference

### Useful Commands

| Command | Description |
|---------|-------------|
| `systemctl status mcp-gateway` | Check gateway status |
| `systemctl restart mcp-gateway` | Restart gateway |
| `journalctl -u mcp-gateway -f` | View live logs |
| `./scripts/health-check.sh` | Quick health check |
| `./scripts/validate-installation.sh` | Full validation |
| `./scripts/generate-token.sh` | Generate new token |

### Important Files

| File | Purpose |
|------|---------|
| `config/gateway.json` | Main configuration |
| `/etc/caddy/Caddyfile` | Reverse proxy config |
| `/etc/systemd/system/mcp-gateway.service` | Systemd service |

### Ports

| Port | Service | Access |
|------|---------|--------|
| 3000 | MCP Gateway | localhost only |
| 80 | HTTP (Caddy) | public |
| 443 | HTTPS (Caddy) | public |

---

## Troubleshooting

If you encounter issues, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for detailed solutions.

Common issues:
- **SSE timeout**: Check Caddy has `flush_interval -1`
- **Service won't start**: Check logs with `journalctl -u mcp-gateway`
- **No tools showing**: Wait 30 seconds after startup, then check server health
