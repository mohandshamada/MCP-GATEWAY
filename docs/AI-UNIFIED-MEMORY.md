# AI Unified Memory Server

This MCP-GATEWAY instance exposes the **ai-unified-memory** MCP server publicly.

## Server Details

| Field | Value |
|-------|-------|
| **Server ID** | `ai-unified-memory` |
| **Status** | Healthy |
| **Tools** | 8 |
| **Local Path** | `/mnt/HC_Volume_104832602/ai-unified-memory` |
| **Wrapper Script** | `/home/MCP-GATEWAY/scripts/ai-unified-memory.sh` |
| **Memory Store** | `/root/.agent-memory` |

## Available Tools

All tools are namespaced as `ai-unified-memory__<tool_name>` when accessed through this gateway:

| Tool | Description |
|------|-------------|
| `memory_read` | Read a memory entry from core, projects, or daily sections |
| `memory_write` | Write a memory entry to core or projects |
| `memory_search` | Full-text search across all memory |
| `memory_append_daily` | Append an entry to today's daily notes |
| `memory_get_project_context` | Get unified context for a specific project path |
| `memory_list_projects` | List all projects with memory |
| `memory_create_project` | Create a new project memory |
| `memory_list_core_keys` | List all available core memory keys |

## Gateway Configuration

The server is registered in `config/gateway.json`:

```json
{
  "id": "ai-unified-memory",
  "transport": "stdio",
  "command": "/home/MCP-GATEWAY/scripts/ai-unified-memory.sh",
  "args": [],
  "enabled": true,
  "lazyLoad": false,
  "timeout": 60000,
  "maxRetries": 3,
  "env": {
    "AGENT_NAME": "mcp-gateway"
  }
}
```

## Wrapper Script

`/home/MCP-GATEWAY/scripts/ai-unified-memory.sh`:

```bash
#!/bin/bash
export PYTHONPATH="/mnt/HC_Volume_104832602/ai-unified-memory/src:$PYTHONPATH"
exec /root/.hermes/hermes-agent/venv/bin/python -m ai_unified_memory
```

## External Usage

Connect to this server via the gateway's SSE endpoint:

```
https://mcp.mshousha.uk/sse
```

With Bearer token authentication:

```bash
curl -H "Authorization: Bearer <token>" \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
     https://mcp.mshousha.uk/rpc
```

## Maintenance

### Update the server

```bash
cd /mnt/HC_Volume_104832602/ai-unified-memory
git pull
pip install -e . --break-system-packages
systemctl restart mcp-gateway
```

### View memory store

```bash
ls -la /root/.agent-memory/
```

### Restart only this server

```bash
systemctl restart mcp-gateway
```
