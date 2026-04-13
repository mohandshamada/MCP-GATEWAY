#!/bin/bash
# Wrapper script to run AI Unified Memory MCP server for MCP-GATEWAY

export PYTHONPATH="/mnt/HC_Volume_104832602/ai-unified-memory/src:$PYTHONPATH"
exec /root/.hermes/hermes-agent/venv/bin/python -m ai_unified_memory "$@"
