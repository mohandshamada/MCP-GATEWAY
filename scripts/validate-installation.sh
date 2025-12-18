#!/bin/bash

# MCP Gateway Installation Validator
# Comprehensive validation of configuration, ports, DNS, SSL, and connectivity
# Based on lessons learned from production deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config/gateway.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Helper functions
pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED++))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARNINGS++))
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Check if running as root for certain tests
check_root() {
    if [ "$EUID" -ne 0 ]; then
        warn "Some tests require root privileges. Run with sudo for complete validation."
        return 1
    fi
    return 0
}

# 1. JSON Configuration Validation
validate_config() {
    header "1. Configuration Validation"

    # Check config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        fail "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    pass "Configuration file exists"

    # Validate JSON syntax
    if ! python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
        if ! node -e "JSON.parse(require('fs').readFileSync('$CONFIG_FILE', 'utf8'))" 2>/dev/null; then
            fail "Configuration file is not valid JSON"
            return 1
        fi
    fi
    pass "JSON syntax is valid"

    # Check jq is available for deeper validation
    if ! command -v jq &>/dev/null; then
        warn "jq not installed - skipping detailed config validation"
        echo "  Install with: apt-get install -y jq"
        return 0
    fi

    # Validate required fields
    local gateway_port=$(jq -r '.gateway.port // empty' "$CONFIG_FILE")
    if [ -z "$gateway_port" ]; then
        fail "Missing required field: gateway.port"
    else
        pass "gateway.port is set: $gateway_port"
    fi

    # Check auth tokens
    local token_count=$(jq -r '.auth.tokens | length' "$CONFIG_FILE")
    if [ "$token_count" -eq 0 ]; then
        fail "No authentication tokens configured"
        echo "  Run: ./scripts/generate-token.sh to create one"
    else
        pass "Authentication tokens configured: $token_count token(s)"
    fi

    # Check servers configured
    local server_count=$(jq -r '.servers | length' "$CONFIG_FILE")
    if [ "$server_count" -eq 0 ]; then
        fail "No MCP servers configured"
    else
        pass "MCP servers configured: $server_count server(s)"

        # List enabled servers
        local enabled=$(jq -r '.servers[] | select(.enabled == true) | .id' "$CONFIG_FILE" | wc -l)
        info "Enabled servers: $enabled"
    fi

    # Validate domain configuration if present
    local domain=$(jq -r '.domain.domain // empty' "$CONFIG_FILE")
    if [ -n "$domain" ] && [ "$domain" != "null" ]; then
        pass "Domain configured: $domain"
    else
        info "No domain configured (localhost only)"
    fi
}

# 2. Port Availability Check
validate_ports() {
    header "2. Port Availability Check"

    local gateway_port=$(jq -r '.gateway.port // 3000' "$CONFIG_FILE" 2>/dev/null || echo "3000")

    # Check if gateway port is available or in use by our service
    if command -v netstat &>/dev/null; then
        local port_user=$(netstat -tlnp 2>/dev/null | grep ":$gateway_port " | awk '{print $7}' | cut -d'/' -f2)
        if [ -z "$port_user" ]; then
            pass "Port $gateway_port is available"
        elif [ "$port_user" = "node" ]; then
            pass "Port $gateway_port is in use by node (MCP Gateway)"
        else
            fail "Port $gateway_port is in use by: $port_user"
        fi
    elif command -v ss &>/dev/null; then
        local port_in_use=$(ss -tlnp 2>/dev/null | grep ":$gateway_port " | wc -l)
        if [ "$port_in_use" -eq 0 ]; then
            pass "Port $gateway_port is available"
        else
            info "Port $gateway_port is in use (check if it's MCP Gateway)"
        fi
    else
        warn "Neither netstat nor ss available - skipping port check"
    fi

    # Check standard web ports
    for port in 80 443; do
        if command -v netstat &>/dev/null; then
            local user=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d'/' -f2)
            if [ -z "$user" ]; then
                info "Port $port is not in use"
            elif [ "$user" = "caddy" ]; then
                pass "Port $port is handled by Caddy"
            else
                warn "Port $port is in use by: $user (expected: caddy)"
            fi
        fi
    done
}

# 3. DNS Resolution Check
validate_dns() {
    header "3. DNS Resolution Check"

    local domain=$(jq -r '.domain.domain // empty' "$CONFIG_FILE" 2>/dev/null)

    if [ -z "$domain" ] || [ "$domain" = "null" ] || [ "$domain" = "localhost" ]; then
        info "No external domain configured - skipping DNS check"
        return 0
    fi

    # Check if dig or nslookup is available
    if command -v dig &>/dev/null; then
        local resolved_ip=$(dig +short "$domain" | head -1)
        if [ -z "$resolved_ip" ]; then
            fail "DNS resolution failed for: $domain"
        else
            pass "DNS resolves: $domain -> $resolved_ip"

            # Get local IP for comparison
            local local_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")
            if [ "$local_ip" != "unknown" ]; then
                # Check if it's a Cloudflare IP (proxied) or direct
                if echo "$resolved_ip" | grep -qE "^(104\.|172\.|103\.21\.|103\.22\.|103\.31\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.)"; then
                    info "Domain is proxied through Cloudflare"
                elif [ "$resolved_ip" = "$local_ip" ]; then
                    pass "DNS points to this server"
                else
                    warn "DNS points to $resolved_ip (this server: $local_ip)"
                fi
            fi
        fi
    elif command -v nslookup &>/dev/null; then
        if nslookup "$domain" &>/dev/null; then
            pass "DNS resolution working for: $domain"
        else
            fail "DNS resolution failed for: $domain"
        fi
    else
        warn "Neither dig nor nslookup available - skipping DNS check"
    fi
}

# 4. SSL Certificate Check
validate_ssl() {
    header "4. SSL Certificate Check"

    local domain=$(jq -r '.domain.domain // empty' "$CONFIG_FILE" 2>/dev/null)

    if [ -z "$domain" ] || [ "$domain" = "null" ] || [ "$domain" = "localhost" ]; then
        info "No external domain configured - skipping SSL check"
        return 0
    fi

    # Check SSL certificate via openssl
    if command -v openssl &>/dev/null; then
        local cert_info=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)

        if [ -z "$cert_info" ]; then
            fail "Could not retrieve SSL certificate for: $domain"
        else
            pass "SSL certificate is installed"

            # Check expiration
            local not_after=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
            if [ -n "$not_after" ]; then
                local expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || echo "0")
                local now_epoch=$(date +%s)
                local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

                if [ "$days_left" -lt 0 ]; then
                    fail "SSL certificate has EXPIRED"
                elif [ "$days_left" -lt 7 ]; then
                    fail "SSL certificate expires in $days_left days - RENEW NOW"
                elif [ "$days_left" -lt 30 ]; then
                    warn "SSL certificate expires in $days_left days"
                else
                    pass "SSL certificate valid for $days_left days"
                fi
            fi
        fi
    else
        warn "openssl not available - skipping SSL check"
    fi

    # Check Let's Encrypt certificate files
    if [ -d "/etc/letsencrypt/live/$domain" ]; then
        pass "Let's Encrypt certificate directory exists"
    fi

    # Check auto-renewal
    if systemctl is-enabled certbot.timer &>/dev/null 2>&1 || systemctl is-enabled certbot-renew.timer &>/dev/null 2>&1; then
        pass "Certificate auto-renewal is enabled"
    else
        warn "Certificate auto-renewal may not be configured"
        echo "  Enable with: systemctl enable certbot.timer"
    fi
}

# 5. Service Status Check
validate_services() {
    header "5. Service Status Check"

    # Check MCP Gateway service
    if systemctl is-active --quiet mcp-gateway 2>/dev/null; then
        pass "MCP Gateway service is running"
    else
        if [ -f "/etc/systemd/system/mcp-gateway.service" ]; then
            fail "MCP Gateway service exists but is not running"
        else
            info "MCP Gateway systemd service not installed"
        fi
    fi

    # Check if service is enabled for autostart
    if systemctl is-enabled --quiet mcp-gateway 2>/dev/null; then
        pass "MCP Gateway service is enabled (auto-start)"
    else
        if [ -f "/etc/systemd/system/mcp-gateway.service" ]; then
            warn "MCP Gateway service is NOT enabled for auto-start"
            echo "  Enable with: systemctl enable mcp-gateway"
        fi
    fi

    # Check Caddy service
    if systemctl is-active --quiet caddy 2>/dev/null; then
        pass "Caddy reverse proxy is running"
    else
        info "Caddy service is not running (may not be installed)"
    fi

    if systemctl is-enabled --quiet caddy 2>/dev/null; then
        pass "Caddy service is enabled (auto-start)"
    fi
}

# 6. Connectivity Check
validate_connectivity() {
    header "6. Connectivity Check"

    local gateway_port=$(jq -r '.gateway.port // 3000' "$CONFIG_FILE" 2>/dev/null || echo "3000")
    local token=$(jq -r '.auth.tokens[0] // empty' "$CONFIG_FILE" 2>/dev/null)

    # Test localhost connectivity
    local health_response=$(curl -s --max-time 5 "http://localhost:$gateway_port/admin/health" \
        -H "Authorization: Bearer $token" 2>/dev/null || echo "")

    if echo "$health_response" | grep -q "healthy"; then
        pass "Gateway health endpoint responding"
    elif [ -n "$health_response" ]; then
        warn "Gateway responding but health status unclear"
    else
        fail "Cannot connect to gateway on localhost:$gateway_port"
    fi

    # Test SSE endpoint
    local sse_response=$(timeout 3 curl -s "http://localhost:$gateway_port/sse" \
        -H "Authorization: Bearer $token" 2>/dev/null | head -1 || echo "")

    if echo "$sse_response" | grep -q "event:"; then
        pass "SSE endpoint is streaming events"
    elif [ -n "$sse_response" ]; then
        warn "SSE endpoint responding but format unclear"
    else
        warn "SSE endpoint not responding (gateway may not be running)"
    fi

    # Test external connectivity if domain configured
    local domain=$(jq -r '.domain.domain // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$domain" ] && [ "$domain" != "null" ] && [ "$domain" != "localhost" ]; then
        local https_response=$(curl -s --max-time 10 "https://$domain/admin/health" \
            -H "Authorization: Bearer $token" 2>/dev/null || echo "")

        if echo "$https_response" | grep -q "healthy"; then
            pass "HTTPS endpoint responding: https://$domain"
        else
            warn "HTTPS endpoint not responding (check Caddy/SSL)"
        fi
    fi
}

# 7. Caddy SSE Configuration Check
validate_caddy_config() {
    header "7. Caddy SSE Configuration Check"

    local caddyfile="/etc/caddy/Caddyfile"

    if [ ! -f "$caddyfile" ]; then
        info "Caddyfile not found at $caddyfile"
        return 0
    fi

    # Check for flush_interval -1 (critical for SSE)
    if grep -q "flush_interval.*-1" "$caddyfile"; then
        pass "SSE flush_interval is correctly set to -1"
    else
        fail "Missing 'flush_interval -1' in Caddyfile"
        echo "  This is CRITICAL for SSE streaming to work properly"
        echo "  Add to your /sse handler: flush_interval -1"
    fi

    # Check for read/write timeouts
    if grep -q "read_timeout.*0" "$caddyfile" && grep -q "write_timeout.*0" "$caddyfile"; then
        pass "Timeout settings configured for long connections"
    else
        warn "Consider adding 'read_timeout 0' and 'write_timeout 0' for SSE"
    fi

    # Validate Caddyfile syntax
    if command -v caddy &>/dev/null; then
        if caddy validate --config "$caddyfile" &>/dev/null; then
            pass "Caddyfile syntax is valid"
        else
            fail "Caddyfile has syntax errors"
            echo "  Run: caddy validate --config $caddyfile"
        fi
    fi
}

# 8. Tool Enumeration Check
validate_tools() {
    header "8. MCP Tools Check"

    local gateway_port=$(jq -r '.gateway.port // 3000' "$CONFIG_FILE" 2>/dev/null || echo "3000")
    local token=$(jq -r '.auth.tokens[0] // empty' "$CONFIG_FILE" 2>/dev/null)

    if [ -z "$token" ]; then
        warn "No token available - skipping tools check"
        return 0
    fi

    # Get tool count
    local tools_response=$(curl -s --max-time 30 -X POST "http://localhost:$gateway_port/message" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}' 2>/dev/null || echo "")

    if [ -z "$tools_response" ]; then
        warn "Could not enumerate tools (gateway may not be running)"
        return 0
    fi

    local tool_count=$(echo "$tools_response" | python3 -c "import sys, json; d=json.load(sys.stdin); print(len(d.get('result', {}).get('tools', [])))" 2>/dev/null || echo "0")

    if [ "$tool_count" -gt 0 ]; then
        pass "Tools available: $tool_count"
    else
        warn "No tools enumerated (servers may still be starting)"
    fi
}

# Summary
print_summary() {
    header "Validation Summary"

    echo ""
    echo -e "  ${GREEN}Passed:${NC}   $PASSED"
    echo -e "  ${RED}Failed:${NC}   $FAILED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
    echo ""

    if [ "$FAILED" -gt 0 ]; then
        echo -e "${RED}Some checks failed. Please review the issues above.${NC}"
        exit 1
    elif [ "$WARNINGS" -gt 0 ]; then
        echo -e "${YELLOW}Validation passed with warnings.${NC}"
        exit 0
    else
        echo -e "${GREEN}All checks passed!${NC}"
        exit 0
    fi
}

# Main
main() {
    echo ""
    echo "MCP Gateway Installation Validator"
    echo "==================================="
    echo ""

    cd "$PROJECT_DIR"

    validate_config
    validate_ports
    validate_dns
    validate_ssl
    validate_services
    validate_connectivity
    validate_caddy_config
    validate_tools

    print_summary
}

# Run main
main "$@"
