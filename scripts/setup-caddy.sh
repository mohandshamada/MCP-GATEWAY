#!/bin/bash

# ============================================================================
# MCP Gateway - Caddy Reverse Proxy Setup with Domain & OAuth Configuration
# This script installs Caddy, configures domain/SSL, and sets up OAuth
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${INSTALL_DIR}/config/gateway.json"
CADDY_CONFIG_DIR="/etc/caddy"
CADDY_CONFIG_FILE="${CADDY_CONFIG_DIR}/Caddyfile"

echo -e "${GREEN}============================================================================${NC}"
echo -e "${GREEN}   MCP Gateway - Domain & OAuth Setup with Caddy${NC}"
echo -e "${GREEN}   Automatic SSL, Reverse Proxy, and Claude App Integration${NC}"
echo -e "${GREEN}============================================================================${NC}"
echo ""

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}==> $1${NC}"
}

prompt_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"

    if [ -n "$default" ]; then
        echo -en "${CYAN}${prompt} [${default}]: ${NC}"
    else
        echo -en "${CYAN}${prompt}: ${NC}"
    fi

    read user_input

    if [ -z "$user_input" ] && [ -n "$default" ]; then
        eval "$var_name='$default'"
    else
        eval "$var_name='$user_input'"
    fi
}

prompt_secret() {
    local prompt="$1"
    local var_name="$2"

    echo -en "${CYAN}${prompt}: ${NC}"
    read -s user_input
    echo ""
    eval "$var_name='$user_input'"
}

confirm() {
    local prompt="$1"
    echo -en "${YELLOW}${prompt} (y/n): ${NC}"
    read -r response
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

generate_token() {
    openssl rand -hex 32
}

# ============================================================================
# Check Root Access
# ============================================================================

check_root() {
    log_step "Checking privileges..."

    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        log_info "Please run: sudo $0"
        exit 1
    fi

    log_info "Running as root - full permissions available"
}

# ============================================================================
# Install Caddy
# ============================================================================

install_caddy() {
    log_step "Installing Caddy web server..."

    if command -v caddy &> /dev/null; then
        log_info "Caddy already installed: $(caddy version)"
        return 0
    fi

    # Install Caddy using official repository
    apt-get update -y
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list

    apt-get update -y
    apt-get install -y caddy

    log_info "Caddy installed successfully: $(caddy version)"
}

# ============================================================================
# Gather Configuration
# ============================================================================

gather_config() {
    log_step "Configuration Setup"
    echo ""
    echo -e "${YELLOW}Please provide the following information:${NC}"
    echo ""

    # Domain configuration
    echo -e "${BLUE}--- Domain Configuration ---${NC}"
    prompt_input "Enter your domain name (e.g., mcp.example.com)" "" DOMAIN

    if [ -z "$DOMAIN" ]; then
        log_error "Domain name is required"
        exit 1
    fi

    prompt_input "SSL email for Let's Encrypt notifications" "admin@${DOMAIN}" SSL_EMAIL

    # OAuth configuration
    echo ""
    echo -e "${BLUE}--- OAuth Configuration (for Claude App Integration) ---${NC}"
    echo -e "${YELLOW}OAuth is optional. Press Enter to skip and use token-based auth.${NC}"
    echo ""

    if confirm "Do you want to configure OAuth for Claude app integration?"; then
        OAUTH_ENABLED=true

        prompt_input "OAuth Client ID" "" OAUTH_CLIENT_ID
        prompt_secret "OAuth Client Secret" OAUTH_CLIENT_SECRET
        prompt_input "OAuth Issuer URL (e.g., https://auth.example.com)" "" OAUTH_ISSUER
        prompt_input "OAuth Authorization URL" "${OAUTH_ISSUER}/authorize" OAUTH_AUTH_URL
        prompt_input "OAuth Token URL" "${OAUTH_ISSUER}/token" OAUTH_TOKEN_URL

        if [ -z "$OAUTH_CLIENT_ID" ] || [ -z "$OAUTH_CLIENT_SECRET" ]; then
            log_warn "OAuth client ID or secret not provided, disabling OAuth"
            OAUTH_ENABLED=false
        fi
    else
        OAUTH_ENABLED=false
        log_info "OAuth disabled, using token-based authentication"
    fi

    # Gateway token
    echo ""
    echo -e "${BLUE}--- Gateway Authentication ---${NC}"

    if confirm "Generate a new secure API token?"; then
        API_TOKEN="sk-$(generate_token)"
        log_info "Generated token: ${API_TOKEN}"
    else
        prompt_secret "Enter your API token" API_TOKEN
        if [ -z "$API_TOKEN" ]; then
            API_TOKEN="sk-$(generate_token)"
            log_info "Generated token: ${API_TOKEN}"
        fi
    fi

    # Summary
    echo ""
    echo -e "${GREEN}============================================================================${NC}"
    echo -e "${GREEN}   Configuration Summary${NC}"
    echo -e "${GREEN}============================================================================${NC}"
    echo -e "Domain:           ${CYAN}${DOMAIN}${NC}"
    echo -e "Public URL:       ${CYAN}https://${DOMAIN}${NC}"
    echo -e "SSL Email:        ${CYAN}${SSL_EMAIL}${NC}"
    echo -e "OAuth Enabled:    ${CYAN}${OAUTH_ENABLED}${NC}"
    if [ "$OAUTH_ENABLED" = true ]; then
        echo -e "OAuth Client ID:  ${CYAN}${OAUTH_CLIENT_ID}${NC}"
        echo -e "OAuth Issuer:     ${CYAN}${OAUTH_ISSUER}${NC}"
    fi
    echo -e "API Token:        ${CYAN}${API_TOKEN:0:20}...${NC}"
    echo ""

    if ! confirm "Proceed with this configuration?"; then
        log_info "Setup cancelled"
        exit 0
    fi
}

# ============================================================================
# Update Gateway Configuration
# ============================================================================

update_gateway_config() {
    log_step "Updating gateway configuration..."

    # Create backup
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

    # Use Node.js to safely update JSON config
    node -e "
const fs = require('fs');
const config = JSON.parse(fs.readFileSync('${CONFIG_FILE}', 'utf8'));

// Update domain configuration
config.domain = {
    domain: '${DOMAIN}',
    publicUrl: 'https://${DOMAIN}',
    ssl: {
        enabled: true,
        email: '${SSL_EMAIL}'
    },
    proxy: {
        enabled: true,
        type: 'caddy'
    }
};

// Update auth configuration
config.auth = config.auth || {};
config.auth.enabled = true;
config.auth.tokens = ['${API_TOKEN}'];

// Update OAuth if enabled
if (${OAUTH_ENABLED}) {
    config.auth.oauth = {
        enabled: true,
        clientId: '${OAUTH_CLIENT_ID}',
        clientSecret: '${OAUTH_CLIENT_SECRET}',
        issuer: '${OAUTH_ISSUER}',
        authorizationUrl: '${OAUTH_AUTH_URL}',
        tokenUrl: '${OAUTH_TOKEN_URL}',
        scopes: ['mcp:read', 'mcp:write']
    };
} else {
    config.auth.oauth = { enabled: false };
}

// Gateway should listen on localhost when behind Caddy
config.gateway.host = '127.0.0.1';

fs.writeFileSync('${CONFIG_FILE}', JSON.stringify(config, null, 2));
console.log('Configuration updated');
"

    log_info "Gateway configuration updated"
}

# ============================================================================
# Create Caddy Configuration
# ============================================================================

create_caddy_config() {
    log_step "Creating Caddy configuration..."

    mkdir -p "$CADDY_CONFIG_DIR"

    cat > "$CADDY_CONFIG_FILE" <<EOF
# MCP Gateway - Caddy Configuration
# Generated on $(date)

# Global options
{
    email ${SSL_EMAIL}
    # Uncomment below for staging/testing
    # acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}

# MCP Gateway reverse proxy
${DOMAIN} {
    # Automatic HTTPS with Let's Encrypt

    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }

    # SSE endpoint - needs special handling for long-lived connections
    handle /sse* {
        reverse_proxy 127.0.0.1:3000 {
            transport http {
                read_timeout 0
                write_timeout 0
            }
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            flush_interval -1
        }
    }

    # Message endpoint for MCP protocol
    handle /message* {
        reverse_proxy 127.0.0.1:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # RPC endpoint
    handle /rpc* {
        reverse_proxy 127.0.0.1:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # Admin endpoints
    handle /admin* {
        reverse_proxy 127.0.0.1:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # Default handler
    handle {
        reverse_proxy 127.0.0.1:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
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

    # Create log directory with proper permissions
    # This must be done BEFORE starting Caddy to prevent service failure
    mkdir -p /var/log/caddy
    chmod 755 /var/log/caddy
    # Try to set caddy ownership, fallback to world-writable if caddy user doesn't exist
    if id "caddy" &>/dev/null; then
        chown caddy:caddy /var/log/caddy
    else
        chmod 777 /var/log/caddy
        log_warn "Caddy user not found, using 777 permissions on log directory"
    fi

    log_info "Caddy configuration created at ${CADDY_CONFIG_FILE}"
}

# ============================================================================
# Create Claude Client Configuration
# ============================================================================

create_client_config() {
    log_step "Creating Claude client configuration..."

    CLIENT_CONFIG_DIR="${INSTALL_DIR}/client-configs"
    mkdir -p "$CLIENT_CONFIG_DIR"

    # Create MCP client configuration for Claude desktop app
    cat > "${CLIENT_CONFIG_DIR}/claude-desktop-config.json" <<EOF
{
  "mcpServers": {
    "mcp-gateway": {
      "url": "https://${DOMAIN}/sse",
      "transport": "sse",
      "headers": {
        "Authorization": "Bearer ${API_TOKEN}"
      }
    }
  }
}
EOF

    # Create direct SSE configuration
    cat > "${CLIENT_CONFIG_DIR}/sse-client-config.json" <<EOF
{
  "name": "MCP Gateway",
  "description": "Federated MCP Gateway with 71 pre-installed tools",
  "endpoint": "https://${DOMAIN}/sse",
  "rpcEndpoint": "https://${DOMAIN}/rpc",
  "messageEndpoint": "https://${DOMAIN}/message",
  "transport": "sse",
  "authentication": {
    "type": "bearer",
    "token": "${API_TOKEN}"
  },
  "features": {
    "tools": 71,
    "servers": 5,
    "capabilities": [
      "filesystem",
      "memory",
      "sequential-thinking",
      "desktop-commander",
      "playwright"
    ]
  }
}
EOF

    # Create OAuth client configuration if enabled
    if [ "$OAUTH_ENABLED" = true ]; then
        cat > "${CLIENT_CONFIG_DIR}/oauth-client-config.json" <<EOF
{
  "name": "MCP Gateway (OAuth)",
  "endpoint": "https://${DOMAIN}/sse",
  "transport": "sse",
  "authentication": {
    "type": "oauth2",
    "clientId": "${OAUTH_CLIENT_ID}",
    "issuer": "${OAUTH_ISSUER}",
    "authorizationUrl": "${OAUTH_AUTH_URL}",
    "tokenUrl": "${OAUTH_TOKEN_URL}",
    "scopes": ["mcp:read", "mcp:write"]
  }
}
EOF
    fi

    # Create curl test script
    cat > "${CLIENT_CONFIG_DIR}/test-connection.sh" <<'TESTEOF'
#!/bin/bash
# Test MCP Gateway connection

DOMAIN="DOMAIN_PLACEHOLDER"
TOKEN="TOKEN_PLACEHOLDER"

echo "Testing MCP Gateway at https://${DOMAIN}..."
echo ""

echo "1. Health check:"
curl -s -H "Authorization: Bearer ${TOKEN}" "https://${DOMAIN}/admin/health" | jq .
echo ""

echo "2. Server status:"
curl -s -H "Authorization: Bearer ${TOKEN}" "https://${DOMAIN}/admin/servers" | jq '.data.servers[] | {id, healthy}'
echo ""

echo "3. Tool count:"
TOOLS=$(curl -s -H "Authorization: Bearer ${TOKEN}" "https://${DOMAIN}/admin/tools" | jq '.data.total')
echo "Total tools available: ${TOOLS}"
TESTEOF

    sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/" "${CLIENT_CONFIG_DIR}/test-connection.sh"
    sed -i "s/TOKEN_PLACEHOLDER/${API_TOKEN}/" "${CLIENT_CONFIG_DIR}/test-connection.sh"
    chmod +x "${CLIENT_CONFIG_DIR}/test-connection.sh"

    log_info "Client configurations created in ${CLIENT_CONFIG_DIR}"
}

# ============================================================================
# Start Services
# ============================================================================

start_services() {
    log_step "Starting services..."

    # Validate Caddy configuration
    log_info "Validating Caddy configuration..."
    caddy validate --config "$CADDY_CONFIG_FILE"

    # Restart Caddy
    log_info "Starting Caddy..."
    systemctl restart caddy
    systemctl enable caddy

    # Restart MCP Gateway
    log_info "Restarting MCP Gateway..."
    systemctl restart mcp-gateway || true

    # Wait for services to start
    sleep 5

    # Check service status
    if systemctl is-active --quiet caddy; then
        log_info "✓ Caddy is running"
    else
        log_error "✗ Caddy failed to start"
        systemctl status caddy
    fi

    if systemctl is-active --quiet mcp-gateway; then
        log_info "✓ MCP Gateway is running"
    else
        log_warn "MCP Gateway service not found or not running"
        log_info "Start manually with: cd ${INSTALL_DIR} && npm start"
    fi
}

# ============================================================================
# Print Summary
# ============================================================================

print_summary() {
    echo ""
    echo -e "${GREEN}============================================================================${NC}"
    echo -e "${GREEN}   Setup Complete!${NC}"
    echo -e "${GREEN}============================================================================${NC}"
    echo ""
    echo -e "${BLUE}Your MCP Gateway is now accessible at:${NC}"
    echo -e "  ${CYAN}https://${DOMAIN}${NC}"
    echo ""
    echo -e "${BLUE}MCP Protocol Endpoints:${NC}"
    echo -e "  SSE:     ${CYAN}https://${DOMAIN}/sse${NC}"
    echo -e "  Message: ${CYAN}https://${DOMAIN}/message${NC}"
    echo -e "  RPC:     ${CYAN}https://${DOMAIN}/rpc${NC}"
    echo ""
    echo -e "${BLUE}Admin Endpoints:${NC}"
    echo -e "  Health:  ${CYAN}https://${DOMAIN}/admin/health${NC}"
    echo -e "  Status:  ${CYAN}https://${DOMAIN}/admin/status${NC}"
    echo -e "  Tools:   ${CYAN}https://${DOMAIN}/admin/tools${NC}"
    echo ""
    echo -e "${BLUE}Authentication:${NC}"
    echo -e "  API Token: ${CYAN}${API_TOKEN}${NC}"
    if [ "$OAUTH_ENABLED" = true ]; then
        echo -e "  OAuth:     ${CYAN}Enabled${NC}"
    fi
    echo ""
    echo -e "${YELLOW}Claude Desktop Integration:${NC}"
    echo -e "  Add to your Claude desktop config (claude_desktop_config.json):"
    echo ""
    echo -e '  "mcpServers": {'
    echo -e '    "mcp-gateway": {'
    echo -e "      \"url\": \"https://${DOMAIN}/sse\","
    echo -e '      "transport": "sse",'
    echo -e '      "headers": {'
    echo -e "        \"Authorization\": \"Bearer ${API_TOKEN}\""
    echo -e '      }'
    echo -e '    }'
    echo -e '  }'
    echo ""
    echo -e "${BLUE}Client configurations saved to:${NC}"
    echo -e "  ${CYAN}${INSTALL_DIR}/client-configs/${NC}"
    echo ""
    echo -e "${YELLOW}Test your connection:${NC}"
    echo -e "  ${CYAN}${INSTALL_DIR}/client-configs/test-connection.sh${NC}"
    echo ""
    echo -e "${GREEN}============================================================================${NC}"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    check_root
    install_caddy
    gather_config
    update_gateway_config
    create_caddy_config
    create_client_config
    start_services
    print_summary
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: sudo $0 [OPTIONS]"
        echo ""
        echo "This script sets up Caddy as a reverse proxy for MCP Gateway with:"
        echo "  - Automatic SSL certificates via Let's Encrypt"
        echo "  - Domain configuration"
        echo "  - OAuth support for Claude app integration"
        echo "  - Client configuration generation"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --non-interactive  Run with environment variables (see below)"
        echo ""
        echo "Environment variables for non-interactive mode:"
        echo "  MCP_DOMAIN         - Your domain name"
        echo "  MCP_SSL_EMAIL      - SSL certificate email"
        echo "  MCP_API_TOKEN      - API authentication token"
        echo "  MCP_OAUTH_ENABLED  - Enable OAuth (true/false)"
        echo "  MCP_OAUTH_CLIENT_ID"
        echo "  MCP_OAUTH_CLIENT_SECRET"
        echo "  MCP_OAUTH_ISSUER"
        exit 0
        ;;
    --non-interactive)
        check_root

        DOMAIN="${MCP_DOMAIN:-}"
        SSL_EMAIL="${MCP_SSL_EMAIL:-admin@${DOMAIN}}"
        API_TOKEN="${MCP_API_TOKEN:-sk-$(generate_token)}"
        OAUTH_ENABLED="${MCP_OAUTH_ENABLED:-false}"
        OAUTH_CLIENT_ID="${MCP_OAUTH_CLIENT_ID:-}"
        OAUTH_CLIENT_SECRET="${MCP_OAUTH_CLIENT_SECRET:-}"
        OAUTH_ISSUER="${MCP_OAUTH_ISSUER:-}"
        OAUTH_AUTH_URL="${MCP_OAUTH_AUTH_URL:-${OAUTH_ISSUER}/authorize}"
        OAUTH_TOKEN_URL="${MCP_OAUTH_TOKEN_URL:-${OAUTH_ISSUER}/token}"

        if [ -z "$DOMAIN" ]; then
            log_error "MCP_DOMAIN environment variable is required"
            exit 1
        fi

        install_caddy
        update_gateway_config
        create_caddy_config
        create_client_config
        start_services
        print_summary
        ;;
    *)
        main "$@"
        ;;
esac
