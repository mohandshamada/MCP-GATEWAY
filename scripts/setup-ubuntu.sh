#!/bin/bash

# ============================================================================
# MCP Gateway Complete Setup Script for Ubuntu Server
# This script fully installs the MCP Gateway with all MCP tools pre-installed
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
MCP_DATA_DIR="${INSTALL_DIR}/mcp-data"
LOG_DIR="${INSTALL_DIR}/logs"

echo -e "${GREEN}============================================================================${NC}"
echo -e "${GREEN}   MCP Gateway Complete Setup for Ubuntu Server${NC}"
echo -e "${GREEN}   All MCP Tools Pre-installed and Ready to Use${NC}"
echo -e "${GREEN}============================================================================${NC}"
echo ""
echo -e "Install directory: ${BLUE}${INSTALL_DIR}${NC}"
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

# ============================================================================
# Check Root Access
# ============================================================================

check_root() {
    log_step "Checking privileges..."

    if [ "$EUID" -ne 0 ]; then
        log_warn "Not running as root. Some operations may require elevated privileges."
        log_warn "Consider running with: sudo $0"
        USE_SUDO="sudo"
    else
        log_info "Running as root - full permissions available"
        USE_SUDO=""
    fi
}

# ============================================================================
# Install System Dependencies
# ============================================================================

install_system_deps() {
    log_step "Installing system dependencies..."

    $USE_SUDO apt-get update -y

    # Install Node.js 22.x if not present or outdated (required for Chrome DevTools MCP)
    if ! command -v node &> /dev/null || [[ $(node -v | cut -d'.' -f1 | tr -d 'v') -lt 22 ]]; then
        log_info "Installing Node.js 22.x..."
        curl -fsSL https://deb.nodesource.com/setup_22.x | $USE_SUDO bash -
        $USE_SUDO apt-get install -y nodejs
    else
        log_info "Node.js already installed: $(node --version)"
    fi

    # Install required system packages for Chrome and other tools
    log_info "Installing system packages for Chrome DevTools..."
    $USE_SUDO apt-get install -y \
        curl \
        wget \
        git \
        build-essential \
        libx11-xcb1 \
        libxcomposite1 \
        libxcursor1 \
        libxdamage1 \
        libxi6 \
        libxtst6 \
        libnss3 \
        libcups2 \
        libxss1 \
        libxrandr2 \
        libasound2 \
        libpangocairo-1.0-0 \
        libatk1.0-0 \
        libatk-bridge2.0-0 \
        libgtk-3-0 \
        libgbm1 \
        libdrm2 \
        libxkbcommon0 \
        fonts-liberation \
        xdg-utils \
        2>/dev/null || log_warn "Some packages may not be available"

    log_info "System dependencies installed"
}

# ============================================================================
# Create Directories with Full Permissions
# ============================================================================

create_directories() {
    log_step "Creating directories with secure permissions (755)..."

    directories=(
        "${MCP_DATA_DIR}"
        "${MCP_DATA_DIR}/data"
        "${MCP_DATA_DIR}/logs"
        "${MCP_DATA_DIR}/cache"
        "${MCP_DATA_DIR}/temp"
        "${MCP_DATA_DIR}/uploads"
        "${MCP_DATA_DIR}/downloads"
        "${MCP_DATA_DIR}/screenshots"
        "${MCP_DATA_DIR}/workspace"
        "${MCP_DATA_DIR}/memory"
        "${LOG_DIR}"
    )

    for dir in "${directories[@]}"; do
        $USE_SUDO mkdir -p "$dir"
        $USE_SUDO chmod 755 "$dir"
        log_info "Created: ${dir}"
    done

    log_info "All directories created with secure permissions (755)"
}

# ============================================================================
# Install NPM Dependencies (Including MCP Servers)
# ============================================================================

install_npm_packages() {
    log_step "Installing npm packages (including MCP servers)..."

    cd "$INSTALL_DIR"

    # Clean install to ensure all packages are fresh
    log_info "Running npm install (this includes all MCP server packages)..."
    npm install

    # Verify MCP packages are installed
    log_info "Verifying MCP package installations..."

    packages=(
        "@modelcontextprotocol/server-filesystem"
        "@modelcontextprotocol/server-memory"
        "@modelcontextprotocol/server-sequential-thinking"
        "@wonderwhy-er/desktop-commander"
        "chrome-devtools-mcp"
    )

    all_installed=true
    for pkg in "${packages[@]}"; do
        if [ -d "node_modules/$pkg" ]; then
            log_info "✓ $pkg installed"
        else
            log_error "✗ $pkg NOT installed"
            all_installed=false
        fi
    done

    if [ "$all_installed" = false ]; then
        log_error "Some MCP packages failed to install. Please check npm errors above."
        exit 1
    fi

    log_info "All npm packages installed successfully"
}

# ============================================================================
# Install Google Chrome
# ============================================================================

install_chrome() {
    log_step "Installing Google Chrome..."

    # Check if Chrome is already installed
    if command -v google-chrome &> /dev/null || command -v google-chrome-stable &> /dev/null; then
        log_info "Google Chrome already installed: $(google-chrome --version 2>/dev/null || google-chrome-stable --version 2>/dev/null)"
        return 0
    fi

    # Add Google Chrome repository
    log_info "Adding Google Chrome repository..."
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | $USE_SUDO gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | $USE_SUDO tee /etc/apt/sources.list.d/google-chrome.list > /dev/null

    # Install Chrome
    log_info "Installing Google Chrome..."
    $USE_SUDO apt-get update -qq
    $USE_SUDO apt-get install -y google-chrome-stable

    log_info "Google Chrome installed: $(google-chrome --version 2>/dev/null || google-chrome-stable --version 2>/dev/null)"
}

# ============================================================================
# Build the Gateway
# ============================================================================

build_gateway() {
    log_step "Building MCP Gateway..."

    cd "$INSTALL_DIR"
    npm run build

    log_info "MCP Gateway built successfully"
}

# ============================================================================
# Set Final Permissions
# ============================================================================

set_permissions() {
    log_step "Setting final permissions..."

    # Set secure permissions on data directories (755 = owner full, others read/execute)
    $USE_SUDO chmod -R 755 "${MCP_DATA_DIR}" 2>/dev/null || true
    $USE_SUDO chmod -R 755 "${LOG_DIR}" 2>/dev/null || true

    # Make config writable by owner only (644 = owner read/write, others read)
    $USE_SUDO chmod 644 "${INSTALL_DIR}/config/gateway.json" 2>/dev/null || true

    # Make scripts executable
    $USE_SUDO chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true

    log_info "Permissions configured (secure: 755 for dirs, 644 for config)"
}

# ============================================================================
# Create Systemd Service
# ============================================================================

create_systemd_service() {
    log_step "Creating systemd service..."

    # Check if systemd is available
    if ! command -v systemctl &> /dev/null || ! pidof systemd &> /dev/null; then
        log_warn "systemd not available (running in container or non-systemd system)"
        log_info "Skipping systemd service creation"
        log_info ""
        log_info "To start the gateway manually, use one of these methods:"
        log_info "  1. Direct: cd ${INSTALL_DIR} && node dist/index.js"
        log_info "  2. NPM:    cd ${INSTALL_DIR} && npm start"
        log_info "  3. Screen: screen -dmS mcp-gateway bash -c 'cd ${INSTALL_DIR} && npm start'"
        log_info "  4. Nohup:  nohup node ${INSTALL_DIR}/dist/index.js > ${LOG_DIR}/mcp-gateway.log 2>&1 &"
        log_info ""

        # Create a helper start script for non-systemd environments
        cat > "${INSTALL_DIR}/start-gateway.sh" <<STARTSCRIPT
#!/bin/bash
# Start MCP Gateway (for non-systemd environments)
cd "${INSTALL_DIR}"
export NODE_ENV=production
export CONFIG_PATH="${INSTALL_DIR}/config/gateway.json"
exec node dist/index.js
STARTSCRIPT
        chmod +x "${INSTALL_DIR}/start-gateway.sh"
        log_info "Created start script: ${INSTALL_DIR}/start-gateway.sh"
        return 0
    fi

    SERVICE_FILE="/etc/systemd/system/mcp-gateway.service"

    $USE_SUDO tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=MCP Gateway Service - Federated MCP Server Aggregation
Documentation=https://github.com/mohandshamada/MCP-Gateway
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node ${INSTALL_DIR}/dist/index.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mcp-gateway

# Environment
Environment=NODE_ENV=production
Environment=CONFIG_PATH=${INSTALL_DIR}/config/gateway.json

# Security settings (relaxed for MCP tools that need file access)
NoNewPrivileges=false
PrivateTmp=false

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

    $USE_SUDO systemctl daemon-reload
    $USE_SUDO systemctl enable mcp-gateway

    log_info "Systemd service created and enabled"
}

# ============================================================================
# Verify Installation
# ============================================================================

verify_installation() {
    log_step "Verifying installation..."

    cd "$INSTALL_DIR"

    # Get token from config file
    CONFIG_FILE="${INSTALL_DIR}/config/gateway.json"
    if [ -f "$CONFIG_FILE" ]; then
        # Extract first token from config using grep/sed (works without jq)
        # First try to get sk- prefixed token, otherwise get any token
        AUTH_TOKEN=$(cat "$CONFIG_FILE" | tr -d '\n' | grep -o '"tokens"[[:space:]]*:[[:space:]]*\[[^]]*\]' | grep -oE '"[^"]{20,}"' | head -1 | tr -d '"')
        if [ -z "$AUTH_TOKEN" ]; then
            AUTH_TOKEN="no-token-found"
            log_warn "Could not extract auth token from config"
        fi
    else
        AUTH_TOKEN="no-token-found"
        log_warn "Config file not found"
    fi

    # Check if gateway can start
    log_info "Testing gateway startup..."

    timeout 30 node dist/index.js &
    GATEWAY_PID=$!
    sleep 10

    # Test health endpoint
    if curl -s http://localhost:3000/admin/health -H "Authorization: Bearer ${AUTH_TOKEN}" | grep -q "healthy"; then
        log_info "✓ Gateway health check passed"
    else
        log_warn "Gateway health check returned unhealthy (MCP servers may still be initializing)"
    fi

    # Get server count
    SERVERS=$(curl -s http://localhost:3000/admin/servers -H "Authorization: Bearer ${AUTH_TOKEN}" 2>/dev/null)
    if echo "$SERVERS" | grep -q "total"; then
        log_info "✓ Gateway API responding correctly"
    fi

    # Stop test instance
    kill $GATEWAY_PID 2>/dev/null || true
    wait $GATEWAY_PID 2>/dev/null || true

    log_info "Installation verification complete"
}

# ============================================================================
# Print Summary
# ============================================================================

print_summary() {
    # Get token from config file for display
    CONFIG_FILE="${INSTALL_DIR}/config/gateway.json"
    if [ -f "$CONFIG_FILE" ]; then
        AUTH_TOKEN=$(cat "$CONFIG_FILE" | tr -d '\n' | grep -o '"tokens"[[:space:]]*:[[:space:]]*\[[^]]*\]' | grep -oE '"[^"]{20,}"' | head -1 | tr -d '"')
        if [ -z "$AUTH_TOKEN" ]; then
            AUTH_TOKEN="(check config/gateway.json for tokens)"
        fi
    else
        AUTH_TOKEN="(check config/gateway.json for tokens)"
    fi

    echo -e "\n${GREEN}============================================================================${NC}"
    echo -e "${GREEN}   Installation Complete!${NC}"
    echo -e "${GREEN}============================================================================${NC}"
    echo ""
    echo -e "${BLUE}MCP Gateway installed at:${NC} ${INSTALL_DIR}"
    echo ""
    echo -e "${YELLOW}Pre-installed MCP Servers:${NC}"
    echo -e "  ✓ Filesystem Server     - File and directory operations"
    echo -e "  ✓ Memory Server         - Knowledge graph memory"
    echo -e "  ✓ Sequential Thinking   - Step-by-step problem solving"
    echo -e "  ✓ Desktop Commander     - Terminal and file editing"
    echo -e "  ✓ Chrome DevTools       - Browser debugging and automation"
    echo ""
    echo -e "${YELLOW}Quick Start:${NC}"
    echo -e "  Development:  cd ${INSTALL_DIR} && npm start"
    echo -e "  Production:   sudo systemctl start mcp-gateway"
    echo -e "  Status:       sudo systemctl status mcp-gateway"
    echo -e "  Logs:         sudo journalctl -u mcp-gateway -f"
    echo ""
    echo -e "${YELLOW}API Token:${NC}"
    echo -e "  ${AUTH_TOKEN}"
    echo ""
    echo -e "${YELLOW}API Endpoints:${NC}"
    echo -e "  Health:       curl -H 'Authorization: Bearer \$TOKEN' http://localhost:3000/admin/health"
    echo -e "  Servers:      curl -H 'Authorization: Bearer \$TOKEN' http://localhost:3000/admin/servers"
    echo -e "  Tools:        curl -H 'Authorization: Bearer \$TOKEN' http://localhost:3000/admin/tools"
    echo -e "  Permissions:  curl -H 'Authorization: Bearer \$TOKEN' http://localhost:3000/admin/permissions"
    echo ""
    echo -e "${YELLOW}Configuration:${NC}"
    echo -e "  Config file:  ${INSTALL_DIR}/config/gateway.json"
    echo -e "  Data dir:     ${MCP_DATA_DIR}"
    echo ""
    echo -e "${GREEN}All MCP tools are pre-installed and ready to use!${NC}"
    echo -e "${GREEN}============================================================================${NC}"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    check_root
    install_system_deps
    install_chrome
    create_directories
    install_npm_packages
    build_gateway
    set_permissions
    create_systemd_service
    verify_installation
    print_summary
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --skip-verify  Skip installation verification"
        echo ""
        echo "This script installs MCP Gateway with all MCP tools pre-installed:"
        echo "  - Filesystem Server"
        echo "  - Memory Server (Knowledge Graph)"
        echo "  - Sequential Thinking"
        echo "  - Desktop Commander"
        echo "  - Chrome DevTools"
        exit 0
        ;;
    --skip-verify)
        check_root
        install_system_deps
        install_chrome
        create_directories
        install_npm_packages
        build_gateway
        set_permissions
        create_systemd_service
        print_summary
        ;;
    *)
        main "$@"
        ;;
esac
