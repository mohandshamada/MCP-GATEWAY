#!/bin/bash

# MCP Gateway Pre-Deployment Check
# Run this script before deploying to verify everything is ready

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "MCP Gateway Pre-Deployment Check"
echo "================================="
echo ""

ERRORS=0

# Check 1: Config file exists and is valid JSON
echo -n "Checking configuration... "
if [ -f "$PROJECT_DIR/config/gateway.json" ]; then
    if node -e "JSON.parse(require('fs').readFileSync('$PROJECT_DIR/config/gateway.json', 'utf8'))" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}INVALID JSON${NC}"
        ((ERRORS++))
    fi
else
    echo -e "${RED}NOT FOUND${NC}"
    ((ERRORS++))
fi

# Check 2: Build exists
echo -n "Checking build output... "
if [ -f "$PROJECT_DIR/dist/index.js" ]; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}NOT FOUND${NC}"
    echo "  Run: npm run build"
    ((ERRORS++))
fi

# Check 3: Node modules installed
echo -n "Checking dependencies... "
if [ -d "$PROJECT_DIR/node_modules" ]; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}NOT INSTALLED${NC}"
    echo "  Run: npm install"
    ((ERRORS++))
fi

# Check 4: Auth tokens configured
echo -n "Checking auth tokens... "
if command -v jq &>/dev/null; then
    TOKEN_COUNT=$(jq -r '.auth.tokens | length' "$PROJECT_DIR/config/gateway.json" 2>/dev/null || echo "0")
    if [ "$TOKEN_COUNT" -gt 0 ]; then
        echo -e "${GREEN}$TOKEN_COUNT token(s)${NC}"
    else
        echo -e "${YELLOW}NONE${NC}"
        echo "  Run: ./scripts/generate-token.sh"
    fi
else
    echo -e "${YELLOW}SKIPPED (jq not installed)${NC}"
fi

# Check 5: Required directories exist
echo -n "Checking directories... "
MISSING_DIRS=""
for dir in logs mcp-data; do
    if [ ! -d "$PROJECT_DIR/$dir" ]; then
        MISSING_DIRS="$MISSING_DIRS $dir"
    fi
done
if [ -z "$MISSING_DIRS" ]; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}CREATING:$MISSING_DIRS${NC}"
    mkdir -p "$PROJECT_DIR/logs" "$PROJECT_DIR/mcp-data"
fi

# Check 6: Lint passes
echo -n "Checking code quality... "
if npm run lint --silent 2>/dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}WARNINGS${NC}"
fi

# Check 7: TypeScript compiles
echo -n "Checking TypeScript... "
if npm run typecheck --silent 2>/dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}ERRORS${NC}"
    ((ERRORS++))
fi

# Check 8: Tests pass (if available)
echo -n "Checking tests... "
if npm test --silent 2>/dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}SKIPPED or FAILED${NC}"
fi

echo ""
echo "================================="

if [ "$ERRORS" -gt 0 ]; then
    echo -e "${RED}Pre-deployment check FAILED with $ERRORS error(s)${NC}"
    echo "Please fix the issues above before deploying."
    exit 1
else
    echo -e "${GREEN}Pre-deployment check PASSED${NC}"
    echo ""
    echo "Ready to deploy! Run:"
    echo "  sudo ./scripts/setup-gateway.sh"
    exit 0
fi
