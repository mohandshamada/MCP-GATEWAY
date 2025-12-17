# MCP Gateway

A production-ready **Federated Gateway Service** for the Model Context Protocol (MCP) that aggregates multiple MCP servers into a single, namespaced, authenticated endpoint with **71 pre-installed tools** ready to use out of the box.

[![Node.js](https://img.shields.io/badge/Node.js-20+-green.svg)](https://nodejs.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.5+-blue.svg)](https://www.typescriptlang.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-purple.svg)](https://modelcontextprotocol.io/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Highlights

- **71 Tools Pre-installed** - 5 MCP servers ready to use immediately
- **Zero Configuration Startup** - Just `npm install && npm start`
- **Caddy Integration** - Automatic SSL with Let's Encrypt, reverse proxy
- **OAuth Support** - Client ID/Secret authentication for Claude app integration
- **Claude Desktop Ready** - Auto-generated configuration for Claude app
- **Ubuntu Server Optimized** - Full root access and 777 permissions for MCP tools
- **Production Hardened** - Circuit breaker, retry logic, health monitoring, graceful degradation
- **Enterprise Features** - Request correlation, persistent configuration, comprehensive logging

---

## Pre-installed MCP Servers

| Server | Tools | Description |
|--------|-------|-------------|
| **Filesystem** | 14 | Read/write files, directories, search, file info |
| **Memory** | 9 | Knowledge graph with entities, relations, observations |
| **Sequential Thinking** | 1 | Step-by-step problem solving with branching |
| **Desktop Commander** | 25 | Terminal commands, file editing, process management |
| **Playwright** | 22 | Browser automation, screenshots, web scraping |
| **Total** | **71** | **Ready to use immediately** |

---

## Quick Start

### One-Command Installation (Ubuntu Server)

```bash
# Clone and run setup
git clone https://github.com/mohandshamada/MCP-Gateway.git
cd MCP-Gateway
sudo ./scripts/setup-ubuntu.sh
```

The setup script will:
- Install Node.js 20+ and system dependencies
- Install all MCP server packages
- Install Playwright browsers (Chromium)
- Create directories with 777 permissions
- Build the gateway
- Create and enable systemd service

### Production Setup with Caddy (SSL + Domain)

For production deployment with HTTPS and domain:

```bash
# Set your domain and email
export DOMAIN="mcp.example.com"
export EMAIL="admin@example.com"

# Run setup scripts in order
sudo ./scripts/setup-ubuntu.sh      # System dependencies
sudo ./scripts/setup-caddy.sh       # Caddy reverse proxy
sudo ./scripts/setup-gateway.sh     # MCP Gateway service
```

The setup scripts will:
- Install and configure Caddy web server
- Set up automatic SSL via Let's Encrypt
- Create systemd services for both Caddy and MCP Gateway
- Configure proper log directories and permissions

See [DEPLOYMENT.md](DEPLOYMENT.md) for detailed deployment instructions.

### Manual Installation

```bash
# Clone repository
git clone https://github.com/mohandshamada/MCP-Gateway.git
cd MCP-Gateway/mcp-gateway

# Install dependencies (includes all MCP servers)
npm install

# Setup Playwright browsers
npm run setup:mcp

# Build
npm run build

# Start
npm start
```

### Verify Installation

Use the built-in health check script (automatically reads token from config):

```bash
./scripts/health-check.sh
```

Or verify manually:

```bash
# Check health (all 5 servers should be healthy)
curl -H "Authorization: Bearer YOUR_TOKEN" http://localhost:3000/admin/health

# Expected: {"status":"healthy","servers":{"total":5,"healthy":5,"unhealthy":0}}

# List all 71 tools
curl -H "Authorization: Bearer YOUR_TOKEN" http://localhost:3000/admin/tools | jq '.data.total'

# Expected: 71
```

---

## Connect Claude as Remote MCP Server (SSE)

MCP Gateway exposes an SSE (Server-Sent Events) endpoint that allows Claude to connect as a **remote MCP server**. This gives Claude access to all 71 tools from anywhere.

### SSE Endpoint URL

```
https://your-domain.com/sse
```

Or for local development:
```
http://localhost:3000/sse
```

### Step-by-Step: Add to Claude as Remote MCP Server

1. **Get your gateway URL and token**

   After running setup, your endpoint will be:
   ```
   SSE Endpoint: https://your-domain.com/sse
   API Token: sk-xxxxxxxxxxxxx (from setup or config)
   ```

2. **Open Claude Desktop Settings**

   - Open Claude Desktop application
   - Go to **Settings** (gear icon)
   - Navigate to **Developer** > **Edit Config**

3. **Add the MCP Gateway as Remote Server**

   Add this to your `claude_desktop_config.json`:

   ```json
   {
     "mcpServers": {
       "mcp-gateway": {
         "url": "https://your-domain.com/sse",
         "transport": "sse",
         "headers": {
           "Authorization": "Bearer YOUR_API_TOKEN"
         }
       }
     }
   }
   ```

4. **Restart Claude Desktop**

   Close and reopen Claude Desktop to load the new MCP server.

5. **Verify Connection**

   In Claude, you should now see 71 tools available from the MCP Gateway.

### Get Your Configuration Automatically

The gateway provides an API endpoint to generate your Claude configuration:

```bash
# Get full configuration with your token embedded
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://your-domain.com/admin/client-config/claude

# Output (ready to use):
{
  "mcpServers": {
    "mcp-gateway": {
      "url": "https://your-domain.com/sse",
      "transport": "sse",
      "headers": {
        "Authorization": "Bearer YOUR_TOKEN"
      }
    }
  }
}
```

### Test SSE Connection

Before adding to Claude, verify the SSE endpoint works:

```bash
# Test SSE connection (should stream events)
curl -N \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Accept: text/event-stream" \
  https://your-domain.com/sse

# Check available tools
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://your-domain.com/admin/tools | jq '.data.total'
# Expected: 71
```

### Configuration File Locations

| Platform | Config File Path |
|----------|-----------------|
| **macOS** | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| **Windows** | `%APPDATA%\Claude\claude_desktop_config.json` |
| **Linux** | `~/.config/Claude/claude_desktop_config.json` |

### Example: Complete Configuration

```json
{
  "mcpServers": {
    "mcp-gateway": {
      "url": "https://mcp.example.com/sse",
      "transport": "sse",
      "headers": {
        "Authorization": "Bearer sk-a1b2c3d4e5f6g7h8i9j0..."
      }
    }
  }
}
```

### Troubleshooting Connection

| Issue | Solution |
|-------|----------|
| "Connection refused" | Check gateway is running: `curl https://your-domain.com/admin/health` |
| "401 Unauthorized" | Verify your API token is correct |
| "SSL certificate error" | Ensure Caddy has valid SSL cert, or use HTTP for local dev |
| "No tools available" | Check server health: `curl .../admin/servers` |
| "Timeout" | SSE needs long-lived connections; check firewall/proxy settings |

---

## Claude Desktop Integration

### Quick Setup

1. Run the Caddy setup script to configure your domain:
   ```bash
   sudo ./scripts/setup-caddy.sh
   ```

2. Get your client configuration:
   ```bash
   curl -H "Authorization: Bearer YOUR_TOKEN" https://your-domain.com/admin/client-config/claude
   ```

3. Add to your Claude Desktop config (`claude_desktop_config.json`):
   ```json
   {
     "mcpServers": {
       "mcp-gateway": {
         "url": "https://your-domain.com/sse",
         "transport": "sse",
         "headers": {
           "Authorization": "Bearer YOUR_TOKEN"
         }
       }
     }
   }
   ```

4. Restart Claude Desktop

### Auto-Generated Configuration

After setup, client configurations are saved to `client-configs/`:

```
client-configs/
├── claude-desktop-config.json   # Claude Desktop configuration
├── sse-client-config.json       # Generic SSE client configuration
├── oauth-client-config.json     # OAuth configuration (if enabled)
└── test-connection.sh           # Connection test script
```

### Get Configuration via API

```bash
# Full configuration with instructions
curl -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/client-config

# Download Claude Desktop config file directly
curl -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/client-config/claude
```

---

## Caddy Reverse Proxy Setup

### Quick Setup (Recommended)

Use the simplified setup script:

```bash
# Set environment variables
export DOMAIN="mcp.example.com"
export EMAIL="admin@example.com"

# Run setup
sudo ./scripts/setup-caddy.sh
```

The script will:
- Create caddy system user if needed
- Install Caddy if not present
- Set up log directory with proper permissions
- Set up ACME storage directories for SSL certificates
- Install and configure Caddyfile from template
- Validate configuration and start service

### Caddyfile Template

The setup uses `scripts/Caddyfile.template` which includes:
- Automatic SSL via Let's Encrypt
- Security headers (X-Frame-Options, XSS protection, etc.)
- SSE endpoint with streaming support (no timeout)
- JSON logging with rotation

### Advanced Setup

For more comprehensive setups with OAuth and client configuration generation:

```bash
sudo ./scripts/caddy-integration.sh
```

This script provides:
- **Interactive configuration** - Prompts for domain, OAuth settings
- **Configuration detection** - Reads MCP Gateway settings automatically
- **Client config generation** - Creates ready-to-use Claude Desktop configs
- **Testing suite** - Runs integration tests after setup

#### Available Commands

```bash
# Interactive setup (default)
sudo ./scripts/caddy-integration.sh

# Check current status
sudo ./scripts/caddy-integration.sh --check

# Run integration tests
sudo ./scripts/caddy-integration.sh --test

# Fix common issues automatically
sudo ./scripts/caddy-integration.sh --fix

# Non-interactive setup (for automation)
sudo MCP_DOMAIN=mcp.example.com ./scripts/caddy-integration.sh --non-interactive
```

### Manual Caddy Configuration

Create `/etc/caddy/Caddyfile`:

```
{
    email admin@example.com
}

your-domain.com {
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }

    # SSE endpoint needs special handling for long-lived connections
    handle /sse* {
        reverse_proxy 127.0.0.1:3000 {
            transport http {
                read_timeout 0
                write_timeout 0
            }
            flush_interval -1
        }
    }

    # All other endpoints
    handle {
        reverse_proxy 127.0.0.1:3000
    }

    log {
        output file /var/log/caddy/mcp-gateway.log {
            roll_size 100mb
            roll_keep 5
        }
        format json
    }
}
```

Start Caddy:

```bash
sudo systemctl enable caddy
sudo systemctl start caddy
```

---

## OAuth Configuration

### Enable OAuth

Edit `config/gateway.json` or use the setup script:

```json
{
  "auth": {
    "enabled": true,
    "tokens": ["your-api-token"],
    "oauth": {
      "enabled": true,
      "clientId": "your-client-id",
      "clientSecret": "your-client-secret",
      "issuer": "https://auth.example.com",
      "authorizationUrl": "https://auth.example.com/authorize",
      "tokenUrl": "https://auth.example.com/token",
      "scopes": ["mcp:read", "mcp:write"]
    }
  }
}
```

### Domain Configuration

```json
{
  "domain": {
    "domain": "mcp.example.com",
    "publicUrl": "https://mcp.example.com",
    "ssl": {
      "enabled": true,
      "email": "admin@example.com"
    },
    "proxy": {
      "enabled": true,
      "type": "caddy"
    }
  }
}
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              MCP Gateway                                     │
│                                                                              │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐ │
│  │     Auth     │──▶│    Router    │──▶│   Registry   │──▶│   Adapters   │ │
│  │  Middleware  │   │  (Namespace) │   │ (Health/Pool)│   │ (Stdio/SSE)  │ │
│  └──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘ │
│         │                                                         │          │
│         │              ┌──────────────────────────────────────────┤          │
│         │              │                                          │          │
│         ▼              ▼                                          ▼          │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                        Production Features                               ││
│  │  • Circuit Breaker    • Retry w/ Backoff    • Request Correlation       ││
│  │  • Rate Limiting      • Health Checks       • Graceful Degradation      ││
│  │  • Config Persistence • Permission Mgmt    • Hot Reload                 ││
│  │  • OAuth Support      • Caddy Integration  • Claude App Ready           ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                 │
          ▼                 ▼                 ▼
   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
   │   Caddy     │   │  Let's      │   │   Claude    │
   │   Proxy     │   │  Encrypt    │   │   Desktop   │
   │   (SSL)     │   │   (SSL)     │   │   (Client)  │
   └─────────────┘   └─────────────┘   └─────────────┘
```

---

## API Reference

### MCP Protocol Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/sse` | GET | Server-Sent Events connection for MCP protocol |
| `/message` | POST | JSON-RPC message endpoint (requires `X-Session-ID`) |
| `/rpc` | POST | Direct JSON-RPC endpoint (stateless) |

### Admin Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/admin/health` | GET | Health check with server status |
| `/admin/status` | GET | Detailed gateway status |
| `/admin/servers` | GET | List all registered servers |
| `/admin/servers` | POST | Register a new server (persisted to config) |
| `/admin/servers/:id` | GET | Get server details with circuit breaker status |
| `/admin/servers/:id` | DELETE | Unregister a server |
| `/admin/servers/:id/restart` | POST | Restart a server |
| `/admin/tools` | GET | List all 71 namespaced tools |
| `/admin/metrics` | GET | Gateway metrics and statistics |

### Client Configuration Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/admin/client-config` | GET | Get full client configuration with instructions |
| `/admin/client-config/claude` | GET | Download Claude Desktop config file |

### Permission Management Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/admin/permissions` | GET | Get current permission status (root/sudo) |
| `/admin/permissions/set` | POST | Set file/directory permissions |
| `/admin/permissions/mkdir` | POST | Create directory with 777 permissions |
| `/admin/permissions/exec` | POST | Execute command with elevated privileges |

### Authentication

All endpoints require Bearer token authentication:

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" https://your-domain.com/admin/health
```

---

## Configuration

### Full Configuration Example (`config/gateway.json`)

```json
{
  "gateway": {
    "host": "0.0.0.0",
    "port": 3000,
    "name": "MCP Gateway",
    "version": "1.0.0"
  },
  "domain": {
    "domain": "mcp.example.com",
    "publicUrl": "https://mcp.example.com",
    "ssl": {
      "enabled": true,
      "email": "admin@example.com"
    },
    "proxy": {
      "enabled": true,
      "type": "caddy"
    }
  },
  "auth": {
    "enabled": true,
    "tokens": ["sk-your-secure-token-here"],
    "oauth": {
      "enabled": false,
      "clientId": null,
      "clientSecret": null
    }
  },
  "servers": [
    {
      "id": "filesystem",
      "transport": "stdio",
      "command": "node",
      "args": ["node_modules/@modelcontextprotocol/server-filesystem/dist/index.js", "/home", "/tmp"],
      "enabled": true,
      "timeout": 60000,
      "maxRetries": 3
    }
  ],
  "settings": {
    "requestTimeout": 120000,
    "enableHealthChecks": true,
    "healthCheckInterval": 30000,
    "enableRateLimiting": true,
    "rateLimit": {
      "windowMs": 60000,
      "maxRequests": 200
    }
  }
}
```

### Server Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | string | required | Unique server ID (used as namespace prefix) |
| `transport` | string | required | `"stdio"` or `"sse"` |
| `command` | string | - | Command to spawn (stdio only) |
| `args` | string[] | `[]` | Command arguments |
| `url` | string | - | SSE endpoint URL (sse only) |
| `env` | object | `{}` | Environment variables |
| `enabled` | boolean | `true` | Whether server is enabled |
| `lazyLoad` | boolean | `false` | Start on-demand |
| `timeout` | number | `60000` | Request timeout (ms) |
| `maxRetries` | number | `3` | Max restart attempts |

### Environment Variables

```bash
# Configuration file path
CONFIG_PATH=/path/to/gateway.json

# Authentication tokens (comma-separated)
MCP_GATEWAY_TOKENS=token1,token2,token3

# Single token
MCP_GATEWAY_TOKEN=your-token

# Node environment
NODE_ENV=production

# Domain (for non-interactive setup)
MCP_DOMAIN=mcp.example.com
MCP_SSL_EMAIL=admin@example.com

# OAuth (for non-interactive setup)
MCP_OAUTH_ENABLED=true
MCP_OAUTH_CLIENT_ID=your-client-id
MCP_OAUTH_CLIENT_SECRET=your-client-secret
MCP_OAUTH_ISSUER=https://auth.example.com
```

---

## Tool Namespacing

All tools are automatically namespaced to prevent collisions:

| Server | Original Tool | Namespaced Tool |
|--------|--------------|-----------------|
| filesystem | `read_file` | `filesystem__read_file` |
| memory | `create_entities` | `memory__create_entities` |
| desktop-commander | `execute_command` | `desktop-commander__execute_command` |
| playwright | `browser_navigate` | `playwright__browser_navigate` |

### Example: Call a Namespaced Tool

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "filesystem__read_file",
    "arguments": {
      "path": "/home/user/document.txt"
    }
  }
}
```

---

## Production Features

### Circuit Breaker Pattern

Protects against cascading failures:

```
States: CLOSED → OPEN → HALF_OPEN → CLOSED

- Failure threshold: 5 consecutive failures
- Recovery timeout: 30 seconds
- Success threshold: 2 successes to close
```

Check circuit breaker status:

```bash
curl -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/servers/filesystem | jq '.data.circuitBreaker'
```

### Retry Logic with Exponential Backoff

```
Retry 1: 1000ms + jitter
Retry 2: 2000ms + jitter
Retry 3: 4000ms + jitter
Max delay: 30000ms
```

### Request Correlation

Every request gets a unique ID for tracing:

```bash
# Request
curl -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/health

# Response includes x-request-id header
# Logs include requestId for correlation
```

### Persistent Configuration

Server changes via API are automatically saved to disk:

```bash
# Register server (automatically saved to gateway.json)
curl -X POST https://your-domain.com/admin/servers \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"id": "new-server", "transport": "stdio", "command": "node", "args": ["server.js"]}'

# Server will persist across restarts
```

### Health Monitoring

Use the built-in health check script:

```bash
# Run health check (reads token from config automatically)
./scripts/health-check.sh

# With custom domain
./scripts/health-check.sh mcp.example.com
```

The health check script:
- Reads auth token from `config/gateway.json` automatically
- Tests localhost direct connection
- Tests HTTPS via Caddy (when domain is configured)
- Shows status of all registered MCP servers
- Returns exit code 0 on success, 1 on failure (CI/monitoring friendly)

Or check manually:

```bash
# Quick health check
curl -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/health

# Detailed metrics
curl -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/metrics
```

---

## Ubuntu Server Deployment

### Setup Scripts

Run the setup scripts in order for a complete deployment:

```bash
# 1. System dependencies (Node.js, Playwright browsers, etc.)
sudo ./scripts/setup-ubuntu.sh

# 2. Caddy reverse proxy (SSL, domain configuration)
export DOMAIN="mcp.example.com"
export EMAIL="admin@example.com"
sudo ./scripts/setup-caddy.sh

# 3. MCP Gateway service (systemd, config validation)
sudo ./scripts/setup-gateway.sh
```

### Systemd Services

Both services are managed via systemd:

```bash
# MCP Gateway
sudo systemctl start mcp-gateway
sudo systemctl stop mcp-gateway
sudo systemctl restart mcp-gateway
sudo systemctl status mcp-gateway
sudo journalctl -u mcp-gateway -f

# Caddy
sudo systemctl start caddy
sudo systemctl stop caddy
sudo systemctl restart caddy
sudo systemctl status caddy
sudo journalctl -u caddy -f
```

### Verify Deployment

```bash
# Run health check
./scripts/health-check.sh

# Or manually
curl -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/health
```

### File Permissions

The gateway runs with full permissions for MCP tool access:

```bash
# Check permission status
curl -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/permissions

# Create directory with 777
curl -X POST https://your-domain.com/admin/permissions/mkdir \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "/opt/data/uploads"}'

# Set permissions
curl -X POST https://your-domain.com/admin/permissions/set \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "/opt/data", "mode": 511, "recursive": true}'
```

### Directory Structure

```
MCP-GATEWAY/
├── config/
│   ├── gateway.json          # Main configuration
│   └── gateway.example.json  # Example configuration
├── client-configs/           # Generated client configurations
│   ├── claude-desktop-config.json
│   ├── sse-client-config.json
│   └── test-connection.sh
├── dist/                     # Compiled JavaScript
├── docs/                     # Documentation
├── logs/                     # Application logs
├── mcp-data/                 # MCP tool data (777 permissions)
│   ├── data/
│   ├── cache/
│   ├── downloads/
│   ├── screenshots/
│   ├── uploads/
│   └── workspace/
├── node_modules/             # Includes all MCP servers
├── scripts/
│   ├── setup-ubuntu.sh       # System dependencies setup
│   ├── setup-caddy.sh        # Caddy reverse proxy setup
│   ├── setup-gateway.sh      # MCP Gateway service setup
│   ├── health-check.sh       # Health check script (reads token from config)
│   ├── Caddyfile.template    # Caddy configuration template
│   └── caddy-integration.sh  # Advanced Caddy integration with OAuth
├── src/                      # TypeScript source
├── tests/                    # Test files
├── DEPLOYMENT.md             # Quick deployment guide
└── README.md                 # This file
```

---

## Development

```bash
# Install dependencies
npm install

# Development mode with hot reload
npm run dev

# Type checking
npm run typecheck

# Linting
npm run lint
npm run lint:fix

# Run tests
npm test
npm run test:watch
npm run test:coverage

# Build for production
npm run build
```

---

## Available Tools by Server

### Filesystem Server (14 tools)

| Tool | Description |
|------|-------------|
| `read_file`, `read_text_file` | Read file contents |
| `read_media_file` | Read images/audio as base64 |
| `read_multiple_files` | Batch file reading |
| `write_file` | Create/overwrite files |
| `edit_file` | Line-based file editing |
| `create_directory` | Create directories |
| `list_directory` | List directory contents |
| `directory_tree` | Recursive tree view |
| `move_file` | Move/rename files |
| `search_files` | Glob pattern search |
| `get_file_info` | File metadata |
| `list_allowed_directories` | Show accessible paths |

### Memory Server (9 tools)

| Tool | Description |
|------|-------------|
| `create_entities` | Create knowledge graph entities |
| `create_relations` | Create entity relationships |
| `add_observations` | Add facts to entities |
| `delete_entities` | Remove entities |
| `delete_observations` | Remove observations |
| `delete_relations` | Remove relationships |
| `read_graph` | Read entire knowledge graph |
| `search_nodes` | Search entities |
| `open_nodes` | Open specific entities |

### Sequential Thinking (1 tool)

| Tool | Description |
|------|-------------|
| `sequentialthinking` | Step-by-step problem solving with revision and branching |

### Desktop Commander (25 tools)

| Tool | Description |
|------|-------------|
| `execute_command` | Run shell commands |
| `read_file`, `write_file` | File operations |
| `edit_block` | Surgical text replacement |
| `start_search`, `stop_search` | Background file search |
| `list_directory` | Directory listing |
| `create_directory` | Create directories |
| `move_file` | Move/rename files |
| `get_config`, `set_config_value` | Configuration management |
| `start_process`, `interact_with_process` | Process management |
| And more... | |

### Playwright (22 tools)

| Tool | Description |
|------|-------------|
| `browser_navigate` | Navigate to URL |
| `browser_screenshot` | Take screenshots |
| `browser_click` | Click elements |
| `browser_type` | Type text |
| `browser_scroll` | Scroll page |
| `browser_select` | Select options |
| `browser_hover` | Hover elements |
| `browser_evaluate` | Execute JavaScript |
| `browser_wait` | Wait for elements |
| And more... | |

---

## Troubleshooting

### SSL Certificate Issues

```bash
# Check Caddy logs
sudo journalctl -u caddy -f

# Validate Caddyfile
caddy validate --config /etc/caddy/Caddyfile

# Force certificate renewal
caddy reload --config /etc/caddy/Caddyfile
```

### Servers show unhealthy

```bash
# Check individual server status
curl -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/servers/filesystem

# Check circuit breaker state
jq '.data.circuitBreaker' # Look for "open" state

# Restart server
curl -X POST -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/servers/filesystem/restart
```

### Permission denied errors

```bash
# Check if running as root
curl -H "Authorization: Bearer $TOKEN" https://your-domain.com/admin/permissions

# If not root, restart with sudo
sudo systemctl restart mcp-gateway
```

### Playwright browser issues

```bash
# Install browsers manually
npx playwright install chromium --with-deps

# Check Playwright installation
npx playwright --version
```

### Configuration not persisting

```bash
# Check config file permissions
ls -la config/gateway.json

# Should be writable
chmod 666 config/gateway.json
```

### Claude Desktop not connecting

1. Verify the gateway is running: `curl https://your-domain.com/admin/health`
2. Check the SSE endpoint: `curl -N https://your-domain.com/sse -H "Authorization: Bearer YOUR_TOKEN"`
3. Verify your `claude_desktop_config.json` has the correct URL and token
4. Restart Claude Desktop after config changes

### Running in Docker/Containers (non-systemd)

If you're running in a container or non-systemd environment:

```bash
# The setup script will detect this and create a start script
./scripts/setup-ubuntu.sh

# Then start manually using one of these methods:
./start-gateway.sh                                    # Helper script created by setup
node dist/index.js                                    # Direct execution
screen -dmS mcp-gateway bash -c 'npm start'           # Screen session
nohup node dist/index.js > logs/mcp-gateway.log 2>&1 &  # Background with nohup
```

### Caddy can't reach the gateway

If Caddy shows "connection refused" or similar errors:

1. **Check gateway is listening on correct interface:**
   ```bash
   # Gateway should listen on 0.0.0.0 for standalone, or 127.0.0.1 behind Caddy
   grep '"host"' config/gateway.json
   ```

2. **Verify log directory exists:**
   ```bash
   # Caddy fails if log directory doesn't exist
   sudo mkdir -p /var/log/caddy
   sudo chmod 755 /var/log/caddy
   # If caddy user exists:
   sudo chown caddy:caddy /var/log/caddy
   ```

3. **Check Caddy can resolve the backend:**
   ```bash
   # Caddy uses 127.0.0.1:3000 (explicit IP) instead of localhost
   # This is more reliable in containers/network namespaces
   curl http://127.0.0.1:3000/admin/health
   ```

---

## Security Considerations

- **Authentication**: Always use strong, unique tokens in production
- **Network**: Behind Caddy, the gateway only listens on localhost
- **SSL**: Let's Encrypt provides automatic HTTPS certificates
- **Permissions**: The gateway runs as root for full MCP tool access
- **Command Execution**: The `/admin/permissions/exec` endpoint blocks dangerous commands
- **Token Storage**: Use environment variables for tokens in production
- **OAuth**: Recommended for production Claude app integration

### Generate Secure Token

```bash
openssl rand -hex 32
# Use as: sk-<generated-hex>
```

### Non-Interactive Setup

For automation/CI:

```bash
# Set required environment variables
export DOMAIN=mcp.example.com
export EMAIL=admin@example.com

# Run setup scripts
sudo ./scripts/setup-ubuntu.sh
sudo ./scripts/setup-caddy.sh
sudo ./scripts/setup-gateway.sh

# Verify deployment
./scripts/health-check.sh
```

For advanced setups with OAuth:

```bash
export MCP_DOMAIN=mcp.example.com
export MCP_SSL_EMAIL=admin@example.com
export MCP_API_TOKEN=sk-$(openssl rand -hex 32)
export MCP_OAUTH_ENABLED=false

sudo -E ./scripts/caddy-integration.sh --non-interactive
```

---

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [Model Context Protocol](https://modelcontextprotocol.io/) - Protocol specification
- [Anthropic](https://anthropic.com/) - MCP SDK and reference servers
- [Fastify](https://fastify.io/) - High-performance web framework
- [Playwright](https://playwright.dev/) - Browser automation
- [Caddy](https://caddyserver.com/) - Automatic HTTPS web server
