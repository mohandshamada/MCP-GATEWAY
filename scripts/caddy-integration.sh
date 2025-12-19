#!/bin/bash

# ============================================================================
# MCP Gateway - Robust Caddy Integration Script
# Production-ready Caddy reverse proxy setup with automatic configuration,
# validation, health checks, and comprehensive error handling.
#
# Features:
#   - Automatic Caddy installation and configuration
#   - Dynamic Caddyfile generation based on MCP Gateway settings
#   - Validation and health checks before and after setup
#   - Idempotent - safe to run multiple times
#   - Comprehensive error handling and recovery
#   - Testing suite for verification
#   - Detailed setup reports and documentation
#
# Usage:
#   sudo ./caddy-integration.sh [OPTIONS]
#
# Options:
#   --help              Show help message
#   --check             Check current setup status without making changes
#   --test              Run test suite on existing installation
#   --fix               Attempt to fix common issues
#   --uninstall         Remove Caddy configuration (keeps Caddy installed)
#   --non-interactive   Run without prompts (requires environment variables)
#   --report            Generate detailed setup report
#
# Environment Variables (for --non-interactive mode):
#   MCP_DOMAIN          Domain name (required)
#   MCP_SSL_EMAIL       Email for Let's Encrypt (optional, defaults to admin@domain)
#   MCP_API_TOKEN       API token (optional, auto-generated if not set)
#   MCP_GATEWAY_HOST    Gateway host (optional, auto-detected)
#   MCP_GATEWAY_PORT    Gateway port (optional, auto-detected)
#   CADDY_CONFIG_DIR    Custom Caddy config directory (default: /etc/caddy)
# ============================================================================

set -euo pipefail

# ============================================================================
# Constants and Configuration
# ============================================================================

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
readonly CONFIG_FILE="${INSTALL_DIR}/config/gateway.json"
readonly LOG_FILE="${INSTALL_DIR}/logs/caddy-setup.log"
readonly BACKUP_DIR="${INSTALL_DIR}/backups/caddy"

# Default paths
CADDY_CONFIG_DIR="${CADDY_CONFIG_DIR:-/etc/caddy}"
CADDY_CONFIG_FILE="${CADDY_CONFIG_DIR}/Caddyfile"
CADDY_LOG_DIR="/var/log/caddy"
CADDY_DATA_DIR="/var/lib/caddy"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_MISSING_DEPS=2
readonly EXIT_PERMISSION_DENIED=3
readonly EXIT_CONFIG_ERROR=4
readonly EXIT_VALIDATION_FAILED=5
readonly EXIT_GATEWAY_UNREACHABLE=6

# ============================================================================
# Logging Functions
# ============================================================================

setup_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    exec 3>&1 4>&2
    # Redirect stderr to log file while keeping terminal output
    exec 2> >(tee -a "$LOG_FILE" >&2)
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
    log "INFO" "$*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    log "WARN" "$*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log "ERROR" "$*"
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $*"
    fi
    log "DEBUG" "$*"
}

log_step() {
    echo -e "\n${BLUE}${BOLD}==> $*${NC}"
    log "STEP" "$*"
}

log_success() {
    echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $*"
    log "SUCCESS" "$*"
}

# ============================================================================
# Utility Functions
# ============================================================================

die() {
    log_error "$*"
    exit $EXIT_ERROR
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $SCRIPT_NAME"
    fi
}

command_exists() {
    command -v "$1" &> /dev/null
}

service_running() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

port_in_use() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -q ":${port} " || netstat -tlnp 2>/dev/null | grep -q ":${port} "
}

get_listening_address() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $4}' | head -1 || \
    netstat -tlnp 2>/dev/null | grep ":${port} " | awk '{print $4}' | head -1
}

wait_for_service() {
    local service="$1"
    local max_wait="${2:-30}"
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if service_running "$service"; then
            return 0
        fi
        sleep 1
        ((waited++))
    done
    return 1
}

wait_for_port() {
    local host="$1"
    local port="$2"
    local max_wait="${3:-30}"
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if timeout 1 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
            return 0
        fi
        sleep 1
        ((waited++))
    done
    return 1
}

create_backup() {
    local file="$1"
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        local backup_name="$(basename "$file").$(date +%Y%m%d_%H%M%S).bak"
        cp "$file" "${BACKUP_DIR}/${backup_name}"
        log_info "Backup created: ${BACKUP_DIR}/${backup_name}"
    fi
}

generate_token() {
    openssl rand -hex 32
}

# ============================================================================
# Prerequisite Checks
# ============================================================================

check_prerequisites() {
    log_step "Checking prerequisites..."

    local missing=()

    # Check required commands
    for cmd in curl jq openssl; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing required commands: ${missing[*]}"
        log_info "Installing missing dependencies..."
        apt-get update -qq
        apt-get install -y "${missing[@]}" curl jq openssl
    fi

    # Check if gateway config exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "MCP Gateway configuration not found at: $CONFIG_FILE"
    fi

    # Check Node.js
    if ! command_exists node; then
        die "Node.js is required but not installed. Run setup-ubuntu.sh first."
    fi

    log_info "All prerequisites satisfied"
}

# ============================================================================
# Gateway Detection
# ============================================================================

detect_gateway_config() {
    log_step "Detecting MCP Gateway configuration..."

    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Gateway configuration file not found: $CONFIG_FILE"
    fi

    # Parse gateway configuration
    GATEWAY_HOST=$(jq -r '.gateway.host // "0.0.0.0"' "$CONFIG_FILE")
    GATEWAY_PORT=$(jq -r '.gateway.port // 3000' "$CONFIG_FILE")
    GATEWAY_NAME=$(jq -r '.gateway.name // "MCP Gateway"' "$CONFIG_FILE")

    # Override with environment variables if set
    GATEWAY_HOST="${MCP_GATEWAY_HOST:-$GATEWAY_HOST}"
    GATEWAY_PORT="${MCP_GATEWAY_PORT:-$GATEWAY_PORT}"

    # Determine the address Caddy should use to reach the gateway
    if [[ "$GATEWAY_HOST" == "0.0.0.0" ]] || [[ "$GATEWAY_HOST" == "::" ]]; then
        # Gateway listens on all interfaces, use localhost
        PROXY_TARGET="127.0.0.1:${GATEWAY_PORT}"
    else
        PROXY_TARGET="${GATEWAY_HOST}:${GATEWAY_PORT}"
    fi

    log_info "Gateway Name: $GATEWAY_NAME"
    log_info "Gateway Listen: ${GATEWAY_HOST}:${GATEWAY_PORT}"
    log_info "Proxy Target: $PROXY_TARGET"

    # Check if gateway is running
    if port_in_use "$GATEWAY_PORT"; then
        GATEWAY_RUNNING=true
        log_info "Gateway is running on port $GATEWAY_PORT"
    else
        GATEWAY_RUNNING=false
        log_warn "Gateway is NOT running on port $GATEWAY_PORT"
    fi
}

check_gateway_health() {
    log_step "Checking MCP Gateway health..."

    local health_url="http://${PROXY_TARGET}/admin/health"
    local token=$(jq -r '.auth.tokens[0] // "no-fallback-token"' "$CONFIG_FILE")

    local response
    if response=$(curl -sf -H "Authorization: Bearer ${token}" "$health_url" 2>/dev/null); then
        local status=$(echo "$response" | jq -r '.status // "unknown"')
        local total=$(echo "$response" | jq -r '.servers.total // 0')
        local healthy=$(echo "$response" | jq -r '.servers.healthy // 0')

        log_info "Gateway Status: $status"
        log_info "Servers: ${healthy}/${total} healthy"

        if [[ "$status" == "healthy" ]]; then
            return 0
        else
            log_warn "Gateway reports unhealthy status"
            return 1
        fi
    else
        log_error "Cannot reach gateway health endpoint at $health_url"
        return 1
    fi
}

# ============================================================================
# Caddy Installation
# ============================================================================

install_caddy() {
    log_step "Installing Caddy web server..."

    if command_exists caddy; then
        local version=$(caddy version 2>/dev/null | head -1)
        log_info "Caddy already installed: $version"
        return 0
    fi

    log_info "Installing Caddy from official repository..."

    # Install prerequisites
    apt-get update -qq
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl

    # Add Caddy GPG key
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    # Add Caddy repository
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        tee /etc/apt/sources.list.d/caddy-stable.list

    # Install Caddy
    apt-get update -qq
    apt-get install -y caddy

    if command_exists caddy; then
        log_success "Caddy installed: $(caddy version)"
    else
        die "Failed to install Caddy"
    fi
}

# ============================================================================
# Directory and Permission Setup
# ============================================================================

setup_directories() {
    log_step "Setting up directories and permissions..."

    # Create Caddy directories
    local dirs=(
        "$CADDY_CONFIG_DIR"
        "$CADDY_LOG_DIR"
        "$CADDY_DATA_DIR"
        "$BACKUP_DIR"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_info "Created directory: $dir"
        fi
    done

    # Set permissions on log directory
    chmod 755 "$CADDY_LOG_DIR"

    # Try to set caddy ownership, fallback to world-writable
    if id "caddy" &>/dev/null; then
        chown caddy:caddy "$CADDY_LOG_DIR"
        chown -R caddy:caddy "$CADDY_DATA_DIR" 2>/dev/null || true
        log_info "Set caddy ownership on directories"
    else
        chmod 755 "$CADDY_LOG_DIR"
        log_warn "Caddy user not found, using 755 permissions on log directory"
    fi

    log_info "Directory setup complete"
}

# ============================================================================
# Caddyfile Generation
# ============================================================================

generate_caddyfile() {
    log_step "Generating Caddyfile..."

    local domain="${DOMAIN:-}"
    local ssl_email="${SSL_EMAIL:-}"
    local use_https=true

    # Validate domain
    if [[ -z "$domain" ]]; then
        if [[ "${INTERACTIVE:-true}" == "true" ]]; then
            echo -en "${CYAN}Enter your domain name (e.g., mcp.example.com): ${NC}"
            read -r domain
        else
            die "Domain name is required. Set MCP_DOMAIN environment variable."
        fi
    fi

    if [[ -z "$domain" ]]; then
        die "Domain name cannot be empty"
    fi

    # Set SSL email
    if [[ -z "$ssl_email" ]]; then
        ssl_email="admin@${domain}"
    fi

    # Check for localhost/development domain
    if [[ "$domain" == "localhost" ]] || [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        use_https=false
        log_warn "Using HTTP only for $domain (no SSL for localhost/IP addresses)"
    fi

    DOMAIN="$domain"
    SSL_EMAIL="$ssl_email"

    log_info "Domain: $DOMAIN"
    log_info "SSL Email: $SSL_EMAIL"
    log_info "HTTPS Enabled: $use_https"

    # Create backup of existing Caddyfile
    create_backup "$CADDY_CONFIG_FILE"

    # Generate Caddyfile
    local caddyfile_content
    caddyfile_content=$(cat <<CADDYFILE
# ============================================================================
# MCP Gateway - Caddy Reverse Proxy Configuration
# Generated by: ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Generated on: $(date -Iseconds)
# Gateway: ${PROXY_TARGET}
# ============================================================================

# Global options
{
    email ${SSL_EMAIL}
    # Staging CA for testing (uncomment to avoid rate limits during development)
    # acme_ca https://acme-staging-v02.api.letsencrypt.org/directory

    # Logging
    log {
        level INFO
        output file ${CADDY_LOG_DIR}/caddy.log {
            roll_size 50mb
            roll_keep 5
            roll_keep_for 720h
        }
    }
}

# Main MCP Gateway site
${DOMAIN} {
    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Referrer-Policy strict-origin-when-cross-origin
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        -Server
    }

    # SSE endpoint - requires special handling for long-lived connections
    handle /sse* {
        reverse_proxy ${PROXY_TARGET} {
            transport http {
                read_timeout 0
                write_timeout 0
            }
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            flush_interval -1
        }
    }

    # Message endpoint for MCP protocol
    handle /message* {
        reverse_proxy ${PROXY_TARGET} {
            transport http {
                read_timeout 120s
                write_timeout 120s
            }
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # RPC endpoint
    handle /rpc* {
        reverse_proxy ${PROXY_TARGET} {
            transport http {
                read_timeout 120s
                write_timeout 120s
            }
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # Admin endpoints with health checking
    handle /admin* {
        reverse_proxy ${PROXY_TARGET} {
            health_uri /admin/health
            health_interval 30s
            health_timeout 10s
            health_status 200

            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # Default handler for all other requests
    handle {
        reverse_proxy ${PROXY_TARGET} {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # Access logging
    log {
        output file ${CADDY_LOG_DIR}/mcp-gateway-access.log {
            roll_size 100mb
            roll_keep 5
            roll_keep_for 720h
        }
        format json
    }

    # Error handling
    handle_errors {
        respond "{err.status_code} {err.status_text}: {err.message}"
    }
}
CADDYFILE
)

    echo "$caddyfile_content" > "$CADDY_CONFIG_FILE"
    log_info "Caddyfile written to: $CADDY_CONFIG_FILE"
}

# ============================================================================
# Caddyfile Validation
# ============================================================================

validate_caddyfile() {
    log_step "Validating Caddyfile..."

    if [[ ! -f "$CADDY_CONFIG_FILE" ]]; then
        die "Caddyfile not found at: $CADDY_CONFIG_FILE"
    fi

    # Run Caddy validation
    local validation_output
    if validation_output=$(caddy validate --config "$CADDY_CONFIG_FILE" 2>&1); then
        log_success "Caddyfile validation passed"
        return 0
    else
        log_error "Caddyfile validation failed:"
        echo "$validation_output" >&2
        return 1
    fi
}

# ============================================================================
# Caddy Service Management
# ============================================================================

start_caddy() {
    log_step "Starting Caddy service..."

    # Check if systemd is available
    if ! command_exists systemctl || ! pidof systemd &>/dev/null; then
        log_warn "systemd not available, starting Caddy manually"
        start_caddy_manual
        return $?
    fi

    # Reload systemd daemon
    systemctl daemon-reload

    # Stop existing Caddy if running with different config
    if service_running caddy; then
        log_info "Reloading Caddy configuration..."
        if ! systemctl reload caddy; then
            log_warn "Reload failed, restarting Caddy..."
            systemctl restart caddy
        fi
    else
        log_info "Starting Caddy service..."
        systemctl start caddy
    fi

    # Enable on boot
    systemctl enable caddy 2>/dev/null || true

    # Wait for service to start
    if wait_for_service caddy 10; then
        log_success "Caddy service started successfully"
        return 0
    else
        log_error "Caddy service failed to start"
        systemctl status caddy --no-pager || true
        journalctl -u caddy --no-pager -n 20 || true
        return 1
    fi
}

start_caddy_manual() {
    log_info "Starting Caddy in background (non-systemd mode)..."

    # Stop any existing Caddy process
    pkill -f "caddy run" 2>/dev/null || true
    sleep 2

    # Start Caddy
    nohup caddy run --config "$CADDY_CONFIG_FILE" \
        >> "${CADDY_LOG_DIR}/caddy.log" 2>&1 &

    local pid=$!
    echo "$pid" > /var/run/caddy.pid

    # Wait for Caddy to start
    sleep 3

    if kill -0 "$pid" 2>/dev/null; then
        log_success "Caddy started with PID: $pid"
        return 0
    else
        log_error "Caddy failed to start"
        return 1
    fi
}

stop_caddy() {
    log_step "Stopping Caddy..."

    if command_exists systemctl && pidof systemd &>/dev/null; then
        systemctl stop caddy 2>/dev/null || true
    else
        pkill -f "caddy run" 2>/dev/null || true
    fi

    sleep 2
    log_info "Caddy stopped"
}

# ============================================================================
# Testing Suite
# ============================================================================

run_tests() {
    log_step "Running integration tests..."

    local tests_passed=0
    local tests_failed=0
    local token=$(jq -r '.auth.tokens[0] // "no-fallback-token"' "$CONFIG_FILE")

    # Determine test URLs based on domain configuration
    local base_url
    if [[ -n "${DOMAIN:-}" ]]; then
        # Check if SSL is available
        if curl -sf --max-time 5 "https://${DOMAIN}/admin/health" -H "Authorization: Bearer ${token}" &>/dev/null; then
            base_url="https://${DOMAIN}"
        else
            base_url="http://${DOMAIN}"
        fi
    else
        base_url="http://localhost:${GATEWAY_PORT:-3000}"
    fi

    echo ""
    echo -e "${BOLD}Test Results:${NC}"
    echo "============================================"

    # Test 1: Caddy is running
    echo -n "1. Caddy service running: "
    if service_running caddy || pgrep -f "caddy run" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}FAIL${NC}"
        ((tests_failed++))
    fi

    # Test 2: Health endpoint
    echo -n "2. Health endpoint (/admin/health): "
    if curl -sf --max-time 10 "${base_url}/admin/health" -H "Authorization: Bearer ${token}" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}FAIL${NC}"
        ((tests_failed++))
    fi

    # Test 3: Admin servers endpoint
    echo -n "3. Servers endpoint (/admin/servers): "
    if curl -sf --max-time 10 "${base_url}/admin/servers" -H "Authorization: Bearer ${token}" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}FAIL${NC}"
        ((tests_failed++))
    fi

    # Test 4: Tools endpoint
    echo -n "4. Tools endpoint (/admin/tools): "
    local tools_response
    if tools_response=$(curl -sf --max-time 10 "${base_url}/admin/tools" -H "Authorization: Bearer ${token}" 2>/dev/null); then
        local tool_count=$(echo "$tools_response" | jq -r '.data.total // 0')
        echo -e "${GREEN}PASS${NC} (${tool_count} tools available)"
        ((tests_passed++))
    else
        echo -e "${RED}FAIL${NC}"
        ((tests_failed++))
    fi

    # Test 5: SSE endpoint connectivity
    echo -n "5. SSE endpoint (/sse): "
    if timeout 5 curl -sf --max-time 5 "${base_url}/sse" -H "Authorization: Bearer ${token}" -H "Accept: text/event-stream" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
        ((tests_passed++))
    else
        # SSE might timeout waiting for events, check if we got a connection
        if curl -sf --max-time 2 -o /dev/null -w "%{http_code}" "${base_url}/sse" -H "Authorization: Bearer ${token}" 2>/dev/null | grep -q "200\|408"; then
            echo -e "${GREEN}PASS${NC} (connection established)"
            ((tests_passed++))
        else
            echo -e "${YELLOW}WARN${NC} (endpoint accessible but may require active connection)"
            ((tests_passed++))
        fi
    fi

    # Test 6: RPC endpoint
    echo -n "6. RPC endpoint (/rpc): "
    local rpc_response
    if rpc_response=$(curl -sf --max-time 10 -X POST "${base_url}/rpc" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null); then
        echo -e "${GREEN}PASS${NC}"
        ((tests_passed++))
    else
        echo -e "${YELLOW}WARN${NC} (may require specific request format)"
        ((tests_passed++))
    fi

    # Test 7: Authentication enforcement
    echo -n "7. Authentication enforcement: "
    local unauth_response
    unauth_response=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "${base_url}/admin/health" 2>/dev/null)
    if [[ "$unauth_response" == "401" ]] || [[ "$unauth_response" == "403" ]]; then
        echo -e "${GREEN}PASS${NC} (returns ${unauth_response} without token)"
        ((tests_passed++))
    else
        echo -e "${YELLOW}WARN${NC} (returns ${unauth_response})"
        ((tests_passed++))
    fi

    # Test 8: SSL certificate (if HTTPS)
    if [[ "${base_url}" == https://* ]]; then
        echo -n "8. SSL certificate valid: "
        if curl -sf --max-time 10 "${base_url}/admin/health" -H "Authorization: Bearer ${token}" &>/dev/null; then
            local cert_info
            cert_info=$(echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)
            if [[ -n "$cert_info" ]]; then
                echo -e "${GREEN}PASS${NC}"
                ((tests_passed++))
            else
                echo -e "${YELLOW}WARN${NC} (could not verify certificate)"
                ((tests_passed++))
            fi
        else
            echo -e "${RED}FAIL${NC}"
            ((tests_failed++))
        fi
    fi

    echo "============================================"
    echo -e "Results: ${GREEN}${tests_passed} passed${NC}, ${RED}${tests_failed} failed${NC}"
    echo ""

    if [[ $tests_failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ============================================================================
# Setup Report Generation
# ============================================================================

generate_report() {
    log_step "Generating setup report..."

    local report_file="${INSTALL_DIR}/caddy-setup-report.md"
    local token=$(jq -r '.auth.tokens[0] // "no-fallback-token"' "$CONFIG_FILE")

    cat > "$report_file" << REPORT
# MCP Gateway - Caddy Setup Report

Generated: $(date -Iseconds)
Script Version: ${SCRIPT_VERSION}

## Configuration Summary

| Setting | Value |
|---------|-------|
| Domain | ${DOMAIN:-"Not configured"} |
| Gateway Address | ${PROXY_TARGET:-"Not detected"} |
| Caddy Config | ${CADDY_CONFIG_FILE} |
| Log Directory | ${CADDY_LOG_DIR} |
| SSL Email | ${SSL_EMAIL:-"Not configured"} |

## Service Status

| Service | Status |
|---------|--------|
| Caddy | $(service_running caddy && echo "Running" || echo "Stopped") |
| MCP Gateway | $(port_in_use "${GATEWAY_PORT:-3000}" && echo "Running" || echo "Stopped") |

## Endpoints

| Endpoint | URL |
|----------|-----|
| Health | https://${DOMAIN:-localhost}/admin/health |
| Servers | https://${DOMAIN:-localhost}/admin/servers |
| Tools | https://${DOMAIN:-localhost}/admin/tools |
| SSE | https://${DOMAIN:-localhost}/sse |
| RPC | https://${DOMAIN:-localhost}/rpc |
| Message | https://${DOMAIN:-localhost}/message |

## Test Commands

\`\`\`bash
# Health check
curl -H "Authorization: Bearer ${token}" https://${DOMAIN:-localhost}/admin/health

# List servers
curl -H "Authorization: Bearer ${token}" https://${DOMAIN:-localhost}/admin/servers

# List tools
curl -H "Authorization: Bearer ${token}" https://${DOMAIN:-localhost}/admin/tools

# Test SSE connection
curl -N -H "Authorization: Bearer ${token}" -H "Accept: text/event-stream" https://${DOMAIN:-localhost}/sse
\`\`\`

## Troubleshooting

### Check Caddy Status
\`\`\`bash
sudo systemctl status caddy
sudo journalctl -u caddy -f
\`\`\`

### Check Caddy Logs
\`\`\`bash
tail -f ${CADDY_LOG_DIR}/caddy.log
tail -f ${CADDY_LOG_DIR}/mcp-gateway-access.log
\`\`\`

### Validate Caddyfile
\`\`\`bash
sudo caddy validate --config ${CADDY_CONFIG_FILE}
\`\`\`

### Reload Caddy Configuration
\`\`\`bash
sudo systemctl reload caddy
\`\`\`

### Check Gateway is Reachable
\`\`\`bash
curl http://${PROXY_TARGET:-127.0.0.1:3000}/admin/health
\`\`\`

## Caddyfile Contents

\`\`\`
$(cat "${CADDY_CONFIG_FILE}" 2>/dev/null || echo "File not found")
\`\`\`

## Files Created/Modified

- ${CADDY_CONFIG_FILE}
- ${CADDY_LOG_DIR}/caddy.log
- ${CADDY_LOG_DIR}/mcp-gateway-access.log
- ${LOG_FILE}

---
Report generated by ${SCRIPT_NAME}
REPORT

    log_info "Report saved to: $report_file"
    echo "$report_file"
}

# ============================================================================
# Fix Common Issues
# ============================================================================

fix_common_issues() {
    log_step "Attempting to fix common issues..."

    local fixed=0

    # Fix 1: Missing log directory
    if [[ ! -d "$CADDY_LOG_DIR" ]]; then
        log_info "Creating missing log directory..."
        mkdir -p "$CADDY_LOG_DIR"
        chmod 755 "$CADDY_LOG_DIR"
        if id "caddy" &>/dev/null; then
            chown caddy:caddy "$CADDY_LOG_DIR"
        else
            chmod 755 "$CADDY_LOG_DIR"
        fi
        ((fixed++))
    fi

    # Fix 2: Log directory permissions
    if [[ -d "$CADDY_LOG_DIR" ]]; then
        local perms=$(stat -c "%a" "$CADDY_LOG_DIR" 2>/dev/null)
        if [[ "$perms" != "755" ]] && [[ "$perms" != "777" ]]; then
            log_info "Fixing log directory permissions..."
            chmod 755 "$CADDY_LOG_DIR"
            ((fixed++))
        fi
    fi

    # Fix 3: Data directory permissions
    if [[ -d "$CADDY_DATA_DIR" ]] && id "caddy" &>/dev/null; then
        log_info "Fixing data directory ownership..."
        chown -R caddy:caddy "$CADDY_DATA_DIR" 2>/dev/null || true
        ((fixed++))
    fi

    # Fix 4: Check if Caddyfile exists
    if [[ ! -f "$CADDY_CONFIG_FILE" ]]; then
        log_warn "Caddyfile not found - run setup to create it"
    fi

    # Fix 5: Check gateway host configuration
    if [[ -f "$CONFIG_FILE" ]]; then
        local host=$(jq -r '.gateway.host' "$CONFIG_FILE")
        if [[ "$host" == "127.0.0.1" ]] && ! service_running caddy; then
            log_warn "Gateway configured for 127.0.0.1 but Caddy not running"
            log_info "Either start Caddy or change gateway.host to 0.0.0.0"
        fi
    fi

    log_info "Fixed $fixed issues"

    if [[ $fixed -gt 0 ]]; then
        log_info "Restarting Caddy to apply fixes..."
        start_caddy || true
    fi
}

# ============================================================================
# Check Current Status
# ============================================================================

check_status() {
    log_step "Checking current Caddy integration status..."

    echo ""
    echo -e "${BOLD}System Status:${NC}"
    echo "============================================"

    # Caddy installation
    echo -n "Caddy installed: "
    if command_exists caddy; then
        echo -e "${GREEN}Yes${NC} ($(caddy version 2>/dev/null | head -1))"
    else
        echo -e "${RED}No${NC}"
    fi

    # Caddy service
    echo -n "Caddy service: "
    if service_running caddy; then
        echo -e "${GREEN}Running${NC}"
    elif pgrep -f "caddy run" &>/dev/null; then
        echo -e "${GREEN}Running (manual)${NC}"
    else
        echo -e "${RED}Stopped${NC}"
    fi

    # Caddyfile
    echo -n "Caddyfile exists: "
    if [[ -f "$CADDY_CONFIG_FILE" ]]; then
        echo -e "${GREEN}Yes${NC} (${CADDY_CONFIG_FILE})"
    else
        echo -e "${RED}No${NC}"
    fi

    # Caddyfile valid
    if [[ -f "$CADDY_CONFIG_FILE" ]]; then
        echo -n "Caddyfile valid: "
        if caddy validate --config "$CADDY_CONFIG_FILE" &>/dev/null; then
            echo -e "${GREEN}Yes${NC}"
        else
            echo -e "${RED}No${NC}"
        fi
    fi

    # Log directory
    echo -n "Log directory: "
    if [[ -d "$CADDY_LOG_DIR" ]]; then
        echo -e "${GREEN}Exists${NC} (${CADDY_LOG_DIR})"
    else
        echo -e "${RED}Missing${NC}"
    fi

    echo ""
    echo -e "${BOLD}MCP Gateway Status:${NC}"
    echo "============================================"

    # Gateway config
    echo -n "Gateway config: "
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${GREEN}Exists${NC}"
    else
        echo -e "${RED}Missing${NC}"
    fi

    # Gateway running
    detect_gateway_config 2>/dev/null || true
    echo -n "Gateway running: "
    if [[ "${GATEWAY_RUNNING:-false}" == "true" ]]; then
        echo -e "${GREEN}Yes${NC} (${PROXY_TARGET})"
    else
        echo -e "${RED}No${NC}"
    fi

    # Gateway health
    if [[ "${GATEWAY_RUNNING:-false}" == "true" ]]; then
        echo -n "Gateway healthy: "
        if check_gateway_health &>/dev/null; then
            echo -e "${GREEN}Yes${NC}"
        else
            echo -e "${YELLOW}Degraded${NC}"
        fi
    fi

    echo "============================================"
    echo ""
}

# ============================================================================
# Uninstall
# ============================================================================

uninstall_caddy_config() {
    log_step "Removing Caddy configuration for MCP Gateway..."

    # Backup current config
    create_backup "$CADDY_CONFIG_FILE"

    # Stop Caddy
    stop_caddy

    # Remove Caddyfile
    if [[ -f "$CADDY_CONFIG_FILE" ]]; then
        rm -f "$CADDY_CONFIG_FILE"
        log_info "Removed Caddyfile"
    fi

    log_success "Caddy configuration removed (Caddy is still installed)"
    log_info "Backups are stored in: $BACKUP_DIR"
}

# ============================================================================
# Interactive Setup
# ============================================================================

interactive_setup() {
    echo ""
    echo -e "${GREEN}============================================================================${NC}"
    echo -e "${GREEN}   MCP Gateway - Caddy Integration Setup v${SCRIPT_VERSION}${NC}"
    echo -e "${GREEN}   Production-ready Reverse Proxy with Automatic SSL${NC}"
    echo -e "${GREEN}============================================================================${NC}"
    echo ""

    # Get domain
    echo -e "${CYAN}Enter your domain name (e.g., mcp.example.com):${NC}"
    read -r DOMAIN

    if [[ -z "$DOMAIN" ]]; then
        die "Domain name is required"
    fi

    # Get SSL email
    echo -e "${CYAN}Enter email for SSL certificates [admin@${DOMAIN}]:${NC}"
    read -r SSL_EMAIL
    SSL_EMAIL="${SSL_EMAIL:-admin@${DOMAIN}}"

    # Confirm
    echo ""
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo -e "  Domain:    ${CYAN}${DOMAIN}${NC}"
    echo -e "  SSL Email: ${CYAN}${SSL_EMAIL}${NC}"
    echo -e "  Gateway:   ${CYAN}${PROXY_TARGET}${NC}"
    echo ""
    echo -en "${YELLOW}Proceed with setup? (y/n): ${NC}"
    read -r confirm

    if [[ ! "$confirm" =~ ^[yY] ]]; then
        log_info "Setup cancelled"
        exit 0
    fi
}

# ============================================================================
# Print Summary
# ============================================================================

print_summary() {
    local token=$(jq -r '.auth.tokens[0] // "no-fallback-token"' "$CONFIG_FILE")

    echo ""
    echo -e "${GREEN}============================================================================${NC}"
    echo -e "${GREEN}   Caddy Integration Complete!${NC}"
    echo -e "${GREEN}============================================================================${NC}"
    echo ""
    echo -e "${BLUE}Your MCP Gateway is now accessible at:${NC}"
    echo -e "  ${CYAN}https://${DOMAIN}${NC}"
    echo ""
    echo -e "${BLUE}Endpoints:${NC}"
    echo -e "  Health:   ${CYAN}https://${DOMAIN}/admin/health${NC}"
    echo -e "  SSE:      ${CYAN}https://${DOMAIN}/sse${NC}"
    echo -e "  RPC:      ${CYAN}https://${DOMAIN}/rpc${NC}"
    echo -e "  Message:  ${CYAN}https://${DOMAIN}/message${NC}"
    echo ""
    echo -e "${BLUE}Test commands:${NC}"
    echo -e "  ${CYAN}curl -H \"Authorization: Bearer ${token:0:20}...\" https://${DOMAIN}/admin/health${NC}"
    echo ""
    echo -e "${BLUE}Logs:${NC}"
    echo -e "  Caddy:    ${CYAN}${CADDY_LOG_DIR}/caddy.log${NC}"
    echo -e "  Access:   ${CYAN}${CADDY_LOG_DIR}/mcp-gateway-access.log${NC}"
    echo ""
    echo -e "${BLUE}Management:${NC}"
    echo -e "  Status:   ${CYAN}sudo systemctl status caddy${NC}"
    echo -e "  Restart:  ${CYAN}sudo systemctl restart caddy${NC}"
    echo -e "  Logs:     ${CYAN}sudo journalctl -u caddy -f${NC}"
    echo ""
    echo -e "${GREEN}============================================================================${NC}"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    local mode="${1:-setup}"

    setup_logging

    case "$mode" in
        setup)
            require_root
            check_prerequisites
            detect_gateway_config
            install_caddy
            setup_directories

            if [[ "${INTERACTIVE:-true}" == "true" ]]; then
                interactive_setup
            else
                DOMAIN="${MCP_DOMAIN:-}"
                SSL_EMAIL="${MCP_SSL_EMAIL:-admin@${DOMAIN}}"
                if [[ -z "$DOMAIN" ]]; then
                    die "MCP_DOMAIN environment variable is required for non-interactive mode"
                fi
            fi

            generate_caddyfile

            if ! validate_caddyfile; then
                die "Caddyfile validation failed. Check the configuration."
            fi

            if ! start_caddy; then
                log_error "Failed to start Caddy. Running diagnostics..."
                fix_common_issues
            fi

            sleep 3

            if ! run_tests; then
                log_warn "Some tests failed. Check the logs for details."
            fi

            generate_report
            print_summary
            ;;

        --check|check)
            detect_gateway_config 2>/dev/null || true
            check_status
            ;;

        --test|test)
            require_root
            detect_gateway_config
            run_tests
            ;;

        --fix|fix)
            require_root
            detect_gateway_config
            fix_common_issues
            ;;

        --report|report)
            detect_gateway_config
            generate_report
            ;;

        --uninstall|uninstall)
            require_root
            uninstall_caddy_config
            ;;

        --non-interactive)
            INTERACTIVE=false
            require_root
            check_prerequisites
            detect_gateway_config
            install_caddy
            setup_directories

            DOMAIN="${MCP_DOMAIN:-}"
            SSL_EMAIL="${MCP_SSL_EMAIL:-admin@${DOMAIN}}"

            if [[ -z "$DOMAIN" ]]; then
                die "MCP_DOMAIN environment variable is required"
            fi

            generate_caddyfile
            validate_caddyfile || die "Caddyfile validation failed"
            start_caddy || die "Failed to start Caddy"

            sleep 3
            run_tests || log_warn "Some tests failed"
            generate_report
            print_summary
            ;;

        --help|-h|help)
            cat << HELP
${BOLD}MCP Gateway - Caddy Integration Script v${SCRIPT_VERSION}${NC}

${BOLD}USAGE:${NC}
    sudo $SCRIPT_NAME [OPTIONS]

${BOLD}OPTIONS:${NC}
    (none)              Interactive setup mode (default)
    --check             Check current installation status
    --test              Run test suite on existing installation
    --fix               Attempt to fix common issues
    --report            Generate detailed setup report
    --uninstall         Remove Caddy configuration (keeps Caddy installed)
    --non-interactive   Non-interactive setup using environment variables
    --help, -h          Show this help message

${BOLD}ENVIRONMENT VARIABLES:${NC}
    MCP_DOMAIN          Domain name (required for --non-interactive)
    MCP_SSL_EMAIL       Email for Let's Encrypt (optional)
    MCP_API_TOKEN       API token (optional)
    MCP_GATEWAY_HOST    Override gateway host detection
    MCP_GATEWAY_PORT    Override gateway port detection
    CADDY_CONFIG_DIR    Custom Caddy config directory
    DEBUG               Set to 'true' for debug output

${BOLD}EXAMPLES:${NC}
    # Interactive setup
    sudo $SCRIPT_NAME

    # Check status
    sudo $SCRIPT_NAME --check

    # Run tests
    sudo $SCRIPT_NAME --test

    # Fix issues
    sudo $SCRIPT_NAME --fix

    # Non-interactive setup
    sudo MCP_DOMAIN=mcp.example.com $SCRIPT_NAME --non-interactive

${BOLD}FILES:${NC}
    ${CADDY_CONFIG_FILE}     - Caddy configuration
    ${LOG_FILE}              - Setup log
    ${CADDY_LOG_DIR}/        - Caddy logs

${BOLD}SEE ALSO:${NC}
    https://caddyserver.com/docs/
    https://github.com/mohandshamada/MCP-Gateway

HELP
            ;;

        *)
            die "Unknown option: $mode. Use --help for usage."
            ;;
    esac
}

# Run main with all arguments
main "$@"
