#!/bin/bash

#===============================================================================
# MCP Gateway - Uninstall Script
#===============================================================================
# This script completely removes MCP Gateway and all related components.
#
# Usage: sudo ./scripts/uninstall.sh [--keep-data] [--keep-caddy] [--force]
#
# Options:
#   --keep-data    Keep the mcp-data directory
#   --keep-caddy   Keep Caddy web server installed
#   --force        Skip confirmation prompts
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

# Default options
KEEP_DATA=false
KEEP_CADDY=false
FORCE=false
REMOVE_PROJECT=false

#===============================================================================
# Parse Arguments
#===============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-data)
            KEEP_DATA=true
            shift
            ;;
        --keep-caddy)
            KEEP_CADDY=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --remove-project)
            REMOVE_PROJECT=true
            shift
            ;;
        -h|--help)
            echo "MCP Gateway Uninstall Script"
            echo ""
            echo "Usage: sudo ./scripts/uninstall.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keep-data       Keep the mcp-data directory"
            echo "  --keep-caddy      Keep Caddy web server installed"
            echo "  --remove-project  Remove the entire project directory"
            echo "  --force           Skip confirmation prompts"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

#===============================================================================
# Helper Functions
#===============================================================================

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
# Print Banner
#===============================================================================

print_banner() {
    echo ""
    echo -e "${RED}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║                    MCP Gateway Uninstall Script                       ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

#===============================================================================
# Confirm Uninstall
#===============================================================================

confirm_uninstall() {
    if [ "$FORCE" = true ]; then
        return 0
    fi

    echo -e "${YELLOW}${BOLD}WARNING: This will remove the following:${NC}"
    echo ""
    echo "  - MCP Gateway systemd service"
    echo "  - Gateway configuration files"
    echo "  - Log files"

    if [ "$KEEP_DATA" = false ]; then
        echo "  - MCP data directory (mcp-data/)"
    fi

    if [ "$KEEP_CADDY" = false ]; then
        echo "  - Caddy configuration for MCP Gateway"
    fi

    if [ "$REMOVE_PROJECT" = true ]; then
        echo -e "  ${RED}- ENTIRE PROJECT DIRECTORY${NC}"
    fi

    echo ""
    read -p "$(echo -e ${RED}Are you sure you want to continue? [y/N]: ${NC})" CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        info "Uninstall cancelled"
        exit 0
    fi
}

#===============================================================================
# Stop Services
#===============================================================================

stop_services() {
    step "Stopping Services"

    # Stop MCP Gateway
    if systemctl is-active --quiet mcp-gateway 2>/dev/null; then
        info "Stopping MCP Gateway service..."
        systemctl stop mcp-gateway
        success "MCP Gateway stopped"
    else
        info "MCP Gateway service not running"
    fi

    # Stop Caddy (optional)
    if [ "$KEEP_CADDY" = false ]; then
        if systemctl is-active --quiet caddy 2>/dev/null; then
            info "Stopping Caddy service..."
            systemctl stop caddy
            success "Caddy stopped"
        fi
    fi
}

#===============================================================================
# Remove Systemd Service
#===============================================================================

remove_service() {
    step "Removing Systemd Service"

    # Disable MCP Gateway service
    if systemctl is-enabled --quiet mcp-gateway 2>/dev/null; then
        info "Disabling MCP Gateway service..."
        systemctl disable mcp-gateway
        success "MCP Gateway service disabled"
    fi

    # Remove service file
    if [ -f /etc/systemd/system/mcp-gateway.service ]; then
        info "Removing MCP Gateway service file..."
        rm -f /etc/systemd/system/mcp-gateway.service
        success "Service file removed"
    fi

    # Reload systemd
    systemctl daemon-reload

    success "Systemd service removed"
}

#===============================================================================
# Remove Caddy Configuration
#===============================================================================

remove_caddy_config() {
    step "Removing Caddy Configuration"

    if [ "$KEEP_CADDY" = true ]; then
        info "Keeping Caddy (--keep-caddy specified)"
        return 0
    fi

    # Check if Caddyfile contains MCP Gateway config
    if [ -f /etc/caddy/Caddyfile ]; then
        if grep -q "MCP Gateway" /etc/caddy/Caddyfile 2>/dev/null; then
            info "Removing MCP Gateway Caddyfile..."
            rm -f /etc/caddy/Caddyfile
            success "Caddyfile removed"
        else
            warn "Caddyfile exists but doesn't appear to be MCP Gateway config"
            warn "Keeping Caddyfile to avoid breaking other services"
        fi
    fi

    # Remove Caddy logs
    if [ -d /var/log/caddy ]; then
        info "Removing Caddy logs..."
        rm -rf /var/log/caddy
        success "Caddy logs removed"
    fi

    success "Caddy configuration cleaned"
}

#===============================================================================
# Remove Data and Logs
#===============================================================================

remove_data() {
    step "Removing Data and Logs"

    # Remove logs directory
    if [ -d "$PROJECT_DIR/logs" ]; then
        info "Removing logs directory..."
        rm -rf "$PROJECT_DIR/logs"
        success "Logs removed"
    fi

    # Remove credentials file
    if [ -f "$PROJECT_DIR/credentials.txt" ]; then
        info "Removing credentials file..."
        rm -f "$PROJECT_DIR/credentials.txt"
        success "Credentials file removed"
    fi

    # Remove mcp-data directory (optional)
    if [ "$KEEP_DATA" = true ]; then
        info "Keeping mcp-data directory (--keep-data specified)"
    else
        if [ -d "$PROJECT_DIR/mcp-data" ]; then
            info "Removing mcp-data directory..."
            rm -rf "$PROJECT_DIR/mcp-data"
            success "mcp-data removed"
        fi
    fi

    # Remove node_modules
    if [ -d "$PROJECT_DIR/node_modules" ]; then
        info "Removing node_modules..."
        rm -rf "$PROJECT_DIR/node_modules"
        success "node_modules removed"
    fi

    # Remove dist directory
    if [ -d "$PROJECT_DIR/dist" ]; then
        info "Removing dist directory..."
        rm -rf "$PROJECT_DIR/dist"
        success "dist removed"
    fi

    # Remove package-lock.json
    if [ -f "$PROJECT_DIR/package-lock.json" ]; then
        info "Removing package-lock.json..."
        rm -f "$PROJECT_DIR/package-lock.json"
        success "package-lock.json removed"
    fi

    success "Data and logs cleaned"
}

#===============================================================================
# Remove Client Configs
#===============================================================================

remove_client_configs() {
    step "Removing Generated Client Configs"

    if [ -d "$PROJECT_DIR/client-configs" ]; then
        info "Removing client-configs directory..."
        rm -rf "$PROJECT_DIR/client-configs"
        success "client-configs removed"
    fi

    # Remove start-gateway.sh if exists
    if [ -f "$PROJECT_DIR/start-gateway.sh" ]; then
        info "Removing start-gateway.sh..."
        rm -f "$PROJECT_DIR/start-gateway.sh"
        success "start-gateway.sh removed"
    fi
}

#===============================================================================
# Reset Gateway Config
#===============================================================================

reset_config() {
    step "Resetting Gateway Configuration"

    if [ -f "$PROJECT_DIR/config/gateway.json" ]; then
        info "Resetting gateway.json to example..."
        if [ -f "$PROJECT_DIR/config/gateway.example.json" ]; then
            cp "$PROJECT_DIR/config/gateway.example.json" "$PROJECT_DIR/config/gateway.json"
            success "Configuration reset to example"
        else
            rm -f "$PROJECT_DIR/config/gateway.json"
            success "Configuration removed"
        fi
    fi
}

#===============================================================================
# Remove Project Directory (Optional)
#===============================================================================

remove_project() {
    if [ "$REMOVE_PROJECT" = false ]; then
        return 0
    fi

    step "Removing Project Directory"

    warn "This will remove the entire project directory: $PROJECT_DIR"

    if [ "$FORCE" = false ]; then
        read -p "$(echo -e ${RED}Are you absolutely sure? [y/N]: ${NC})" CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
            info "Keeping project directory"
            return 0
        fi
    fi

    # Move to parent directory before removing
    cd /tmp

    info "Removing $PROJECT_DIR..."
    rm -rf "$PROJECT_DIR"
    success "Project directory removed"
}

#===============================================================================
# Print Summary
#===============================================================================

print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║                   MCP Gateway Uninstalled Successfully                ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""

    echo -e "${BOLD}Removed:${NC}"
    echo "  ✓ MCP Gateway systemd service"
    echo "  ✓ Log files"
    echo "  ✓ node_modules and dist directories"
    echo "  ✓ Generated client configurations"

    if [ "$KEEP_DATA" = false ]; then
        echo "  ✓ mcp-data directory"
    else
        echo -e "  ${YELLOW}○ mcp-data directory (kept)${NC}"
    fi

    if [ "$KEEP_CADDY" = false ]; then
        echo "  ✓ Caddy configuration"
    else
        echo -e "  ${YELLOW}○ Caddy (kept)${NC}"
    fi

    if [ "$REMOVE_PROJECT" = true ]; then
        echo "  ✓ Project directory"
    else
        echo ""
        echo -e "${BOLD}Project directory preserved at:${NC}"
        echo -e "  ${CYAN}$PROJECT_DIR${NC}"
        echo ""
        echo -e "${BOLD}To reinstall:${NC}"
        echo "  cd $PROJECT_DIR"
        echo "  sudo ./scripts/install.sh"
    fi

    echo ""

    if [ "$KEEP_CADDY" = false ]; then
        echo -e "${YELLOW}Note: Caddy web server is still installed.${NC}"
        echo "To completely remove Caddy: apt-get remove caddy"
    fi

    echo ""
}

#===============================================================================
# Main
#===============================================================================

main() {
    print_banner
    check_root
    confirm_uninstall
    stop_services
    remove_service
    remove_caddy_config
    remove_data
    remove_client_configs
    reset_config
    remove_project
    print_summary
}

# Run main
main "$@"
