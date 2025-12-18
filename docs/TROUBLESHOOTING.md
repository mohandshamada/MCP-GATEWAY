# MCP Gateway Troubleshooting Guide

This guide covers common issues encountered during installation and operation of the MCP Gateway, along with their solutions.

## Table of Contents

1. [SSE Streaming Issues](#sse-streaming-issues)
2. [Service & Startup Issues](#service--startup-issues)
3. [DNS & Domain Issues](#dns--domain-issues)
4. [SSL/TLS Certificate Issues](#ssltls-certificate-issues)
5. [Configuration Issues](#configuration-issues)
6. [Connectivity Issues](#connectivity-issues)
7. [Tool Enumeration Issues](#tool-enumeration-issues)

---

## SSE Streaming Issues

### Problem: Client times out after receiving only one event

**Symptoms:**
- Claude Desktop connects but then times out
- `curl` to `/sse` endpoint receives one event then hangs
- Timeout error after approximately 30 seconds

**Cause:** Caddy reverse proxy is buffering responses instead of streaming them immediately.

**Solution:** Update your Caddyfile with proper SSE configuration:

```caddy
handle /sse* {
    reverse_proxy 127.0.0.1:3000 {
        transport http {
            read_timeout 0      # Disable read timeout
            write_timeout 0     # Disable write timeout
        }
        flush_interval -1       # CRITICAL: Disable buffering
    }
}
```

**Verification:**
```bash
# Should receive multiple events (not just one)
timeout 30 curl -v http://localhost:3000/sse \
  -H "Authorization: Bearer YOUR_TOKEN" 2>&1 | grep -c "event:"
# Expected: More than 1
```

### Problem: Connection closes immediately

**Symptoms:**
- SSE connection opens and closes right away
- No events received at all

**Cause:** Authentication failure or missing token.

**Solution:**
```bash
# Verify your token is correct
TOKEN=$(jq -r '.auth.tokens[0]' config/gateway.json)
echo "Token: $TOKEN"

# Test with correct token
curl -v http://localhost:3000/sse -H "Authorization: Bearer $TOKEN"
```

---

## Service & Startup Issues

### Problem: Service doesn't start after reboot

**Symptoms:**
- MCP Gateway not running after VPS restart
- Must manually run `systemctl start mcp-gateway`

**Cause:** Service not enabled for auto-start.

**Solution:**
```bash
# Enable service to start on boot
sudo systemctl enable mcp-gateway
sudo systemctl enable caddy

# Verify
systemctl is-enabled mcp-gateway
# Should output: enabled
```

### Problem: Service fails to start

**Symptoms:**
- `systemctl start mcp-gateway` fails
- Service shows as "failed" in status

**Diagnosis:**
```bash
# Check service status
sudo systemctl status mcp-gateway

# View detailed logs
sudo journalctl -u mcp-gateway -n 50 --no-pager

# Common issues to look for:
# - "Cannot find module" = missing dependencies
# - "EADDRINUSE" = port already in use
# - "SyntaxError" = invalid configuration
```

**Common Solutions:**

1. **Missing dependencies:**
   ```bash
   cd /path/to/MCP-GATEWAY
   npm install
   npm run build
   ```

2. **Port already in use:**
   ```bash
   # Find what's using port 3000
   sudo netstat -tlnp | grep :3000

   # Kill the process or change gateway port in config
   ```

3. **Invalid configuration:**
   ```bash
   # Validate JSON
   jq . config/gateway.json

   # If error, fix the JSON syntax
   ```

### Problem: Gateway starts but crashes immediately

**Symptoms:**
- Service starts then stops within seconds
- Logs show repeated restart attempts

**Solution:**
```bash
# Check for the actual error
sudo journalctl -u mcp-gateway -f

# Run manually to see full error output
cd /path/to/MCP-GATEWAY
node dist/index.js
```

---

## DNS & Domain Issues

### Problem: Domain doesn't resolve

**Symptoms:**
- `dig your-domain.com` returns nothing
- Browser shows DNS_PROBE_FINISHED_NXDOMAIN

**Solution:**
1. Check DNS records in your provider (Cloudflare, Route53, etc.)
2. Ensure A record points to your VPS IP:
   ```bash
   # Get your VPS IP
   curl -s https://api.ipify.org

   # Verify DNS
   dig your-domain.com +short
   # Should return your VPS IP
   ```
3. Wait for DNS propagation (up to 48 hours, usually minutes)

### Problem: Cloudflare Error 521

**Symptoms:**
- Browser shows "Error 521: Web server is down"
- Direct IP access works but domain doesn't

**Cause:** Cloudflare can't reach your origin server.

**Solution:**
1. Verify your server is accessible:
   ```bash
   curl -v http://YOUR_VPS_IP:3000/admin/health
   ```

2. Check firewall allows Cloudflare IPs:
   ```bash
   # List Cloudflare IPs
   curl -s https://www.cloudflare.com/ips-v4

   # Ensure firewall allows these ranges on port 443
   ```

3. Verify Cloudflare DNS settings point to correct IP

---

## SSL/TLS Certificate Issues

### Problem: SSL certificate errors

**Symptoms:**
- Browser shows "Your connection is not private"
- `curl` fails with SSL verification error

**Solutions:**

1. **Certificate not installed:**
   ```bash
   # Install with Certbot
   sudo apt install certbot
   sudo certbot certonly --standalone -d your-domain.com
   ```

2. **Certificate expired:**
   ```bash
   # Check expiration
   echo | openssl s_client -servername your-domain.com \
     -connect your-domain.com:443 2>/dev/null | \
     openssl x509 -noout -dates

   # Renew if expired
   sudo certbot renew
   ```

3. **Using Caddy (recommended - auto SSL):**
   ```bash
   # Caddy handles certificates automatically
   # Just ensure domain is correctly configured in Caddyfile
   ```

### Problem: Certificate auto-renewal not working

**Symptoms:**
- Certificate expires
- No renewal attempts in logs

**Solution:**
```bash
# Enable certbot timer
sudo systemctl enable certbot.timer
sudo systemctl start certbot.timer

# Test renewal
sudo certbot renew --dry-run

# Check timer status
systemctl list-timers certbot*
```

---

## Configuration Issues

### Problem: "gateway.json is not valid JSON"

**Symptoms:**
- Setup script fails with JSON error
- Gateway won't start

**Diagnosis:**
```bash
# Find the exact error
python3 -c "import json; json.load(open('config/gateway.json'))"

# Or use jq
jq . config/gateway.json
```

**Common JSON mistakes:**
- Trailing comma after last item in array/object
- Missing comma between items
- Unquoted strings
- Single quotes instead of double quotes

### Problem: Servers not connecting

**Symptoms:**
- Gateway starts but shows 0 tools
- "Connection refused" in logs

**Solution:**
```bash
# Check server configuration
jq '.servers[] | {id, enabled, command}' config/gateway.json

# Verify commands exist
which node
ls node_modules/@modelcontextprotocol/

# Check for missing packages
npm install
```

---

## Connectivity Issues

### Problem: Can't connect from external network

**Symptoms:**
- localhost works fine
- External connections timeout or refused

**Diagnosis:**
```bash
# Check what ports are listening
sudo netstat -tlnp | grep -E ":(80|443|3000)"

# Check firewall rules
sudo ufw status
# or
sudo iptables -L
```

**Solution:**
```bash
# Allow required ports
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# If using Caddy, it handles 80/443
# Gateway should only listen on localhost:3000
```

### Problem: Health check fails

**Symptoms:**
- `/admin/health` returns error or timeout
- Validation script shows connectivity failure

**Solution:**
```bash
# Test direct connection
curl -v http://localhost:3000/admin/health \
  -H "Authorization: Bearer $(jq -r '.auth.tokens[0]' config/gateway.json)"

# Check if gateway is running
ps aux | grep "node.*dist/index.js"

# Check logs for errors
sudo journalctl -u mcp-gateway -n 20
```

---

## Tool Enumeration Issues

### Problem: No tools available (0 tools)

**Symptoms:**
- `tools/list` returns empty array
- Claude Desktop shows no tools

**Causes & Solutions:**

1. **Servers still starting:**
   ```bash
   # Wait 30 seconds after gateway start
   # Then retry
   ```

2. **All servers disabled:**
   ```bash
   # Check enabled servers
   jq '.servers[] | select(.enabled == true) | .id' config/gateway.json

   # Enable servers in config
   ```

3. **Server command not found:**
   ```bash
   # Verify MCP servers are installed
   ls node_modules/@modelcontextprotocol/

   # Reinstall if needed
   npm install
   ```

4. **Server crashed:**
   ```bash
   # Check gateway logs for server errors
   sudo journalctl -u mcp-gateway | grep -i "error\|fail"
   ```

### Problem: Some tools missing

**Symptoms:**
- Only partial tool list (e.g., 50 instead of 71)
- Specific server's tools not appearing

**Solution:**
```bash
# Check which servers are healthy
curl -s http://localhost:3000/admin/status \
  -H "Authorization: Bearer $(jq -r '.auth.tokens[0]' config/gateway.json)" | \
  jq '.data.registry.servers[] | {id, health}'

# Restart specific server by restarting gateway
sudo systemctl restart mcp-gateway
```

---

## Quick Diagnostic Commands

Run these commands to quickly diagnose issues:

```bash
# 1. Check all services
systemctl status mcp-gateway caddy

# 2. Validate configuration
./scripts/validate-installation.sh

# 3. Quick health check
./scripts/health-check.sh

# 4. View recent logs
sudo journalctl -u mcp-gateway -n 50 --no-pager

# 5. Test SSE streaming
timeout 10 curl -s http://localhost:3000/sse \
  -H "Authorization: Bearer $(jq -r '.auth.tokens[0]' config/gateway.json)" | head -20

# 6. Count available tools
curl -s -X POST http://localhost:3000/message \
  -H "Authorization: Bearer $(jq -r '.auth.tokens[0]' config/gateway.json)" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  python3 -c "import sys,json; print(len(json.load(sys.stdin)['result']['tools']))"
```

---

## Getting Help

If you're still experiencing issues:

1. Run the validation script and share the output:
   ```bash
   ./scripts/validate-installation.sh 2>&1 | tee validation-output.txt
   ```

2. Collect logs:
   ```bash
   sudo journalctl -u mcp-gateway --since "1 hour ago" > gateway-logs.txt
   ```

3. Open an issue at: https://github.com/mohandshamada/MCP-GATEWAY/issues
   - Include validation output
   - Include relevant logs
   - Describe the steps to reproduce
