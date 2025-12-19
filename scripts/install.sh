#!/bin/bash

#===============================================================================
# MCP Gateway - Complete Installation Script
#===============================================================================
# This script performs a complete installation of MCP Gateway including:
# - System dependencies (Node.js 22+, Chrome, Caddy)
# - Domain configuration with SSL
# - OAuth server setup
# - Systemd services
#
# Usage: sudo ./scripts/install.sh
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/gateway.json"

#===============================================================================
# Helper Functions
#===============================================================================

print_banner() {
    echo ""
    echo -e "${MAGENTA}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║   ███╗   ███╗ ██████╗██████╗      ██████╗  █████╗ ████████╗███████╗   ║"
    echo "║   ████╗ ████║██╔════╝██╔══██╗    ██╔════╝ ██╔══██╗╚══██╔══╝██╔════╝   ║"
    echo "║   ██╔████╔██║██║     ██████╔╝    ██║  ███╗███████║   ██║   █████╗     ║"
    echo "║   ██║╚██╔╝██║██║     ██╔═══╝     ██║   ██║██╔══██║   ██║   ██╔══╝     ║"
    echo "║   ██║ ╚═╝ ██║╚██████╗██║         ╚██████╔╝██║  ██║   ██║   ███████╗   ║"
    echo "║   ╚═╝     ╚═╝ ╚═════╝╚═╝          ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝   ║"
    echo "║                                                                       ║"
    echo "║                    Complete Installation Script                       ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

step() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

prompt() {
    local prompt_text="$1"
    local default_value="$2"
    local result

    if [ -n "$default_value" ]; then
        echo -ne "${YELLOW}$prompt_text [${default_value}]: ${NC}"
        read -r result
        echo "${result:-$default_value}"
    else
        echo -ne "${YELLOW}$prompt_text: ${NC}"
        read -r result
        echo "$result"
    fi
}

prompt_password() {
    local prompt_text="$1"
    local result

    echo -ne "${YELLOW}$prompt_text: ${NC}"
    read -rs result
    echo ""
    echo "$result"
}

generate_secret() {
    openssl rand -hex 32
}

#===============================================================================
# Check Root
#===============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

#===============================================================================
# Step 1: System Dependencies
#===============================================================================

install_system_deps() {
    step "Step 1: Installing System Dependencies"

    info "Updating package lists..."
    apt-get update -qq

    info "Installing essential packages..."
    apt-get install -y -qq \
        curl \
        wget \
        gnupg \
        ca-certificates \
        apt-transport-https \
        software-properties-common \
        jq \
        openssl \
        git

    success "Essential packages installed"
}

#===============================================================================
# Step 2: Install Node.js 22+
#===============================================================================

install_nodejs() {
    step "Step 2: Installing Node.js 22+"

    # Check if Node.js is already installed and is version 22+
    if command -v node &>/dev/null; then
        NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$NODE_VERSION" -ge 22 ]; then
            success "Node.js $(node -v) already installed"
            return 0
        else
            warn "Node.js $(node -v) found, but version 22+ required"
            info "Upgrading Node.js..."
        fi
    fi

    info "Adding NodeSource repository for Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -

    info "Installing Node.js 22..."
    apt-get install -y nodejs

    success "Node.js $(node -v) installed"
    success "npm $(npm -v) installed"
}

#===============================================================================
# Step 3: Install Google Chrome (for Chrome DevTools MCP)
#===============================================================================

install_chrome() {
    step "Step 3: Installing Google Chrome"

    if command -v google-chrome &>/dev/null || command -v google-chrome-stable &>/dev/null; then
        success "Google Chrome already installed"
        return 0
    fi

    info "Adding Google Chrome repository..."
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list

    info "Installing Google Chrome..."
    apt-get update -qq
    apt-get install -y google-chrome-stable

    success "Google Chrome installed"
}

#===============================================================================
# Step 4: Install Caddy Web Server
#===============================================================================

install_caddy() {
    step "Step 4: Installing Caddy Web Server"

    if command -v caddy &>/dev/null; then
        success "Caddy already installed ($(caddy version | head -1))"
        return 0
    fi

    info "Adding Caddy repository..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list

    info "Installing Caddy..."
    apt-get update -qq
    apt-get install -y caddy

    # Create log directory
    mkdir -p /var/log/caddy
    chown caddy:caddy /var/log/caddy

    success "Caddy installed"
}

#===============================================================================
# Step 5: Collect Configuration
#===============================================================================

collect_config() {
    step "Step 5: Configuration"

    echo -e "${BOLD}Please provide the following configuration details:${NC}"
    echo ""

    # Domain
    DOMAIN=$(prompt "Enter your domain (e.g., mcp.example.com)")
    if [ -z "$DOMAIN" ]; then
        error "Domain is required"
        exit 1
    fi

    # Email for SSL
    SSL_EMAIL=$(prompt "Enter email for SSL certificates (Let's Encrypt)" "admin@${DOMAIN#*.}")

    # Gateway name
    GATEWAY_NAME=$(prompt "Enter gateway name" "MCP Gateway")

    echo ""
    echo -e "${BOLD}OAuth Server Configuration:${NC}"
    echo ""

    # OAuth Client ID
    DEFAULT_CLIENT_ID="mcp-client-$(openssl rand -hex 4)"
    OAUTH_CLIENT_ID=$(prompt "Enter OAuth Client ID" "$DEFAULT_CLIENT_ID")

    # OAuth Client Secret
    echo -e "${YELLOW}Enter OAuth Client Secret (leave empty to generate):${NC} "
    read -rs OAUTH_CLIENT_SECRET
    echo ""
    if [ -z "$OAUTH_CLIENT_SECRET" ]; then
        OAUTH_CLIENT_SECRET=$(generate_secret)
        info "Generated OAuth Client Secret"
    fi

    # Generate auth token
    AUTH_TOKEN=$(generate_secret)

    echo ""
    success "Configuration collected"

    # Display summary
    echo ""
    echo -e "${BOLD}Configuration Summary:${NC}"
    echo -e "  Domain:           ${CYAN}$DOMAIN${NC}"
    echo -e "  SSL Email:        ${CYAN}$SSL_EMAIL${NC}"
    echo -e "  Gateway Name:     ${CYAN}$GATEWAY_NAME${NC}"
    echo -e "  OAuth Client ID:  ${CYAN}$OAUTH_CLIENT_ID${NC}"
    echo -e "  OAuth Secret:     ${CYAN}${OAUTH_CLIENT_SECRET:0:8}...${NC}"
    echo ""

    read -p "$(echo -e ${YELLOW}Is this correct? [Y/n]: ${NC})" CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn] ]]; then
        error "Installation cancelled. Please run the script again."
        exit 1
    fi
}

#===============================================================================
# Step 6: Install MCP Gateway
#===============================================================================

install_gateway() {
    step "Step 6: Installing MCP Gateway"

    cd "$PROJECT_DIR"

    info "Installing npm dependencies..."
    npm install --silent

    info "Building project..."
    npm run build

    # Create directories
    info "Creating data directories..."
    mkdir -p mcp-data/{data,logs,cache,temp,uploads,downloads,screenshots,workspace}
    chmod -R 777 mcp-data
    mkdir -p logs
    chmod 777 logs

    success "MCP Gateway installed"
}

#===============================================================================
# Step 7: Configure Gateway
#===============================================================================

configure_gateway() {
    step "Step 7: Configuring Gateway"

    info "Creating gateway configuration..."

    cat > "$CONFIG_FILE" << EOF
{
  "gateway": {
    "host": "0.0.0.0",
    "port": 3000,
    "name": "$GATEWAY_NAME",
    "version": "1.0.0"
  },
  "domain": {
    "domain": "$DOMAIN",
    "publicUrl": "https://$DOMAIN",
    "ssl": {
      "enabled": true,
      "email": "$SSL_EMAIL"
    },
    "proxy": {
      "enabled": true,
      "type": "caddy"
    }
  },
  "auth": {
    "enabled": true,
    "tokens": [
      "$AUTH_TOKEN"
    ],
    "oauth": {
      "enabled": false
    }
  },
  "servers": [
    {
      "id": "filesystem",
      "transport": "stdio",
      "command": "node",
      "args": [
        "node_modules/@modelcontextprotocol/server-filesystem/dist/index.js",
        "/home",
        "/tmp",
        "/var",
        "/root"
      ],
      "enabled": true,
      "lazyLoad": false,
      "timeout": 60000,
      "maxRetries": 3,
      "env": {}
    },
    {
      "id": "memory",
      "transport": "stdio",
      "command": "node",
      "args": [
        "node_modules/@modelcontextprotocol/server-memory/dist/index.js"
      ],
      "enabled": true,
      "lazyLoad": false,
      "timeout": 60000,
      "maxRetries": 3,
      "env": {}
    },
    {
      "id": "sequential-thinking",
      "transport": "stdio",
      "command": "node",
      "args": [
        "node_modules/@modelcontextprotocol/server-sequential-thinking/dist/index.js"
      ],
      "enabled": true,
      "lazyLoad": false,
      "timeout": 60000,
      "maxRetries": 3,
      "env": {}
    },
    {
      "id": "desktop-commander",
      "transport": "stdio",
      "command": "node",
      "args": [
        "node_modules/@wonderwhy-er/desktop-commander/dist/index.js"
      ],
      "enabled": true,
      "lazyLoad": false,
      "timeout": 60000,
      "maxRetries": 3,
      "env": {
        "ALLOWED_PATHS": "/home,/tmp,/var,/root",
        "ENABLE_FILE_OPERATIONS": "true",
        "ENABLE_TERMINAL": "true"
      }
    },
    {
      "id": "chrome-devtools",
      "transport": "stdio",
      "command": "npx",
      "args": [
        "-y",
        "chrome-devtools-mcp@latest"
      ],
      "enabled": true,
      "lazyLoad": false,
      "timeout": 120000,
      "maxRetries": 3,
      "env": {}
    }
  ],
  "oauthServer": {
    "enabled": true,
    "tokenExpiresIn": 3600,
    "refreshTokenExpiresIn": 86400,
    "clients": [
      {
        "clientId": "$OAUTH_CLIENT_ID",
        "clientSecret": "$OAUTH_CLIENT_SECRET",
        "name": "MCP Gateway Client",
        "scopes": ["mcp:read", "mcp:write", "mcp:admin"],
        "grantTypes": ["client_credentials", "password", "refresh_token"]
      }
    ]
  },
  "settings": {
    "requestTimeout": 120000,
    "enableHealthChecks": true,
    "healthCheckInterval": 30000,
    "enableHotReload": true,
    "enableRateLimiting": true,
    "rateLimit": {
      "windowMs": 60000,
      "maxRequests": 200
    }
  }
}
EOF

    success "Gateway configuration created"
}

#===============================================================================
# Step 8: Configure Caddy
#===============================================================================

configure_caddy() {
    step "Step 8: Configuring Caddy Reverse Proxy"

    info "Creating Caddyfile..."

    cat > /etc/caddy/Caddyfile << EOF
# MCP Gateway - Caddy Configuration
# Auto-generated by install.sh

{
    email $SSL_EMAIL
}

$DOMAIN {
    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }

    # SSE endpoint - CRITICAL: flush_interval -1 for streaming
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

    # Logging
    log {
        output file /var/log/caddy/mcp-gateway.log {
            roll_size 100mb
            roll_keep 5
        }
        format json
    }
}
EOF

    info "Validating Caddy configuration..."
    if caddy validate --config /etc/caddy/Caddyfile; then
        success "Caddy configuration valid"
    else
        error "Caddy configuration invalid"
        exit 1
    fi

    success "Caddy configured"
}

#===============================================================================
# Step 9: Create Systemd Services
#===============================================================================

create_services() {
    step "Step 9: Creating Systemd Services"

    info "Creating MCP Gateway service..."

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

[Install]
WantedBy=multi-user.target
EOF

    info "Reloading systemd..."
    systemctl daemon-reload

    info "Enabling services..."
    systemctl enable mcp-gateway
    systemctl enable caddy

    success "Systemd services created and enabled"
}

#===============================================================================
# Step 10: Start Services
#===============================================================================

start_services() {
    step "Step 10: Starting Services"

    info "Starting Caddy..."
    systemctl restart caddy
    sleep 2

    if systemctl is-active --quiet caddy; then
        success "Caddy started"
    else
        error "Caddy failed to start"
        journalctl -u caddy -n 20 --no-pager
        exit 1
    fi

    info "Starting MCP Gateway..."
    systemctl restart mcp-gateway
    sleep 5

    if systemctl is-active --quiet mcp-gateway; then
        success "MCP Gateway started"
    else
        error "MCP Gateway failed to start"
        journalctl -u mcp-gateway -n 20 --no-pager
        exit 1
    fi

    success "All services started"
}

#===============================================================================
# Step 11: Verify Installation
#===============================================================================

verify_installation() {
    step "Step 11: Verifying Installation"

    info "Waiting for services to initialize..."
    sleep 5

    # Test health endpoint
    info "Testing health endpoint..."
    HEALTH=$(curl -s --max-time 10 "http://localhost:3000/admin/health" \
        -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null | jq -r '.status // "error"' 2>/dev/null || echo "unreachable")

    if [ "$HEALTH" = "healthy" ]; then
        success "Health check passed"
    else
        warn "Health check returned: $HEALTH"
    fi

    # Count tools
    info "Counting available tools..."
    TOOL_COUNT=$(curl -s --max-time 30 -X POST "http://localhost:3000/message" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}' 2>/dev/null | \
        python3 -c "import sys, json; d=json.load(sys.stdin); print(len(d.get('result', {}).get('tools', [])))" 2>/dev/null || echo "0")

    if [ "$TOOL_COUNT" -gt 0 ]; then
        success "Tools available: $TOOL_COUNT"
    else
        warn "No tools enumerated yet (servers may still be starting)"
    fi

    # Test HTTPS
    info "Testing HTTPS endpoint..."
    sleep 3
    HTTPS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN/admin/health" \
        -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null || echo "000")

    if [ "$HTTPS_STATUS" = "200" ]; then
        success "HTTPS endpoint working"
    else
        warn "HTTPS returned status: $HTTPS_STATUS (SSL certificate may still be provisioning)"
    fi
}

#===============================================================================
# Step 12: Get OAuth Token
#===============================================================================

get_oauth_token() {
    step "Step 12: Generating OAuth Token"

    info "Requesting OAuth access token..."

    OAUTH_RESPONSE=$(curl -s --max-time 10 -X POST "http://localhost:3000/oauth/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=$OAUTH_CLIENT_ID&client_secret=$OAUTH_CLIENT_SECRET" 2>/dev/null)

    OAUTH_ACCESS_TOKEN=$(echo "$OAUTH_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null)

    if [ -n "$OAUTH_ACCESS_TOKEN" ]; then
        success "OAuth token generated"
    else
        warn "Could not generate OAuth token (OAuth server may still be starting)"
        OAUTH_ACCESS_TOKEN="<token-will-be-generated-on-first-request>"
    fi
}

#===============================================================================
# Print Summary
#===============================================================================

print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║              🎉 MCP Gateway Installation Complete! 🎉                 ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}                           CONNECTION DETAILS                             ${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}SSE Endpoint (with Bearer Token):${NC}"
    echo -e "  ${GREEN}https://$DOMAIN/sse${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}Full SSE Link with Token:${NC}"
    echo -e "  ${GREEN}https://$DOMAIN/sse?token=$AUTH_TOKEN${NC}"
    echo ""

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}                           AUTHENTICATION                                 ${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}Bearer Token:${NC}"
    echo -e "  ${GREEN}$AUTH_TOKEN${NC}"
    echo ""

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}                           OAUTH CREDENTIALS                              ${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}OAuth Token Endpoint:${NC}"
    echo -e "  ${GREEN}https://$DOMAIN/oauth/token${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}OAuth Client ID:${NC}"
    echo -e "  ${GREEN}$OAUTH_CLIENT_ID${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}OAuth Client Secret:${NC}"
    echo -e "  ${GREEN}$OAUTH_CLIENT_SECRET${NC}"
    echo ""

    if [ -n "$OAUTH_ACCESS_TOKEN" ] && [ "$OAUTH_ACCESS_TOKEN" != "<token-will-be-generated-on-first-request>" ]; then
        echo -e "${CYAN}${BOLD}OAuth Access Token (expires in 1 hour):${NC}"
        echo -e "  ${GREEN}$OAUTH_ACCESS_TOKEN${NC}"
        echo ""

        echo -e "${CYAN}${BOLD}SSE Link with OAuth Token:${NC}"
        echo -e "  ${GREEN}https://$DOMAIN/sse?token=$OAUTH_ACCESS_TOKEN${NC}"
        echo ""
    fi

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}                         CLAUDE DESKTOP CONFIG                            ${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "Add this to your Claude Desktop configuration:"
    echo ""
    echo -e "${GREEN}{"
    echo -e "  \"mcpServers\": {"
    echo -e "    \"mcp-gateway\": {"
    echo -e "      \"url\": \"https://$DOMAIN/sse\","
    echo -e "      \"headers\": {"
    echo -e "        \"Authorization\": \"Bearer $AUTH_TOKEN\""
    echo -e "      }"
    echo -e "    }"
    echo -e "  }"
    echo -e "}${NC}"
    echo ""

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}                           USEFUL COMMANDS                                ${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "  ${CYAN}Check status:${NC}     systemctl status mcp-gateway"
    echo -e "  ${CYAN}View logs:${NC}        journalctl -u mcp-gateway -f"
    echo -e "  ${CYAN}Restart:${NC}          systemctl restart mcp-gateway"
    echo -e "  ${CYAN}Health check:${NC}     $PROJECT_DIR/scripts/health-check.sh"
    echo -e "  ${CYAN}Validate:${NC}         $PROJECT_DIR/scripts/validate-installation.sh"
    echo -e "  ${CYAN}Uninstall:${NC}        sudo $PROJECT_DIR/scripts/uninstall.sh"
    echo ""

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Save credentials to file
    CREDS_FILE="$PROJECT_DIR/credentials.txt"
    cat > "$CREDS_FILE" << EOF
MCP Gateway Credentials
========================
Generated: $(date)

Domain: https://$DOMAIN
SSE Endpoint: https://$DOMAIN/sse

Bearer Token: $AUTH_TOKEN

OAuth Token Endpoint: https://$DOMAIN/oauth/token
OAuth Client ID: $OAUTH_CLIENT_ID
OAuth Client Secret: $OAUTH_CLIENT_SECRET

Full SSE Link: https://$DOMAIN/sse?token=$AUTH_TOKEN

Claude Desktop Config:
{
  "mcpServers": {
    "mcp-gateway": {
      "url": "https://$DOMAIN/sse",
      "headers": {
        "Authorization": "Bearer $AUTH_TOKEN"
      }
    }
  }
}
EOF
    chmod 600 "$CREDS_FILE"

    echo -e "${YELLOW}Credentials saved to: ${CYAN}$CREDS_FILE${NC}"
    echo ""
}

#===============================================================================
# Main
#===============================================================================

main() {
    print_banner
    check_root

    install_system_deps
    install_nodejs
    install_chrome
    install_caddy
    collect_config
    install_gateway
    configure_gateway
    configure_caddy
    create_services
    start_services
    verify_installation
    get_oauth_token
    print_summary
}

# Run main
main "$@"
