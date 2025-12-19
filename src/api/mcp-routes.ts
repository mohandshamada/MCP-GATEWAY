import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { z } from 'zod';
import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { getGateway } from '../core/gateway.js';
import { type JsonRpcRequest } from '../adapters/index.js';
import { createChildLogger, type Logger } from '../utils/logger.js';

const log: Logger = createChildLogger({ component: 'mcp-api' });

// Get the directory of the current module for asset loading
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const projectRoot = join(__dirname, '..', '..');

// Cache the icon content for performance
let iconSvgCache: string | null = null;

/**
 * Load and cache the gateway icon
 */
function getIconSvg(): string | null {
  if (iconSvgCache !== null) {
    return iconSvgCache;
  }

  const iconPath = join(projectRoot, 'assets', 'icon.svg');
  if (existsSync(iconPath)) {
    try {
      iconSvgCache = readFileSync(iconPath, 'utf-8');
      log.debug({ iconPath }, 'Gateway icon loaded');
    } catch (error) {
      log.warn({ error, iconPath }, 'Failed to load gateway icon');
      iconSvgCache = '';
    }
  } else {
    log.debug({ iconPath }, 'Gateway icon not found');
    iconSvgCache = '';
  }

  return iconSvgCache || null;
}

/**
 * JSON-RPC request schema
 * Note: id is optional to support JSON-RPC "Notifications" (messages without id)
 * that some clients (like Claude Cloud) send during connection probing.
 * When id is missing, we default to 0 to maintain response compatibility.
 */
const JsonRpcRequestSchema = z.object({
  jsonrpc: z.literal('2.0'),
  id: z.union([z.string(), z.number(), z.null()]).optional().default(0),
  method: z.string(),
  params: z.unknown().optional(),
});

/**
 * Active SSE connections
 */
const sseConnections: Map<string, FastifyReply> = new Map();

/**
 * Register MCP routes
 */
export async function registerMcpRoutes(fastify: FastifyInstance): Promise<void> {
  /**
   * GET /icon.svg - Gateway icon for MCP clients
   * Returns the gateway icon that can be displayed in Claude Desktop and other MCP clients
   */
  fastify.get('/icon.svg', async (_request: FastifyRequest, reply: FastifyReply) => {
    const iconSvg = getIconSvg();

    if (!iconSvg) {
      return reply.status(404).send({ error: 'Icon not found' });
    }

    reply.header('Content-Type', 'image/svg+xml');
    reply.header('Cache-Control', 'public, max-age=86400'); // Cache for 24 hours
    return reply.send(iconSvg);
  });

  /**
   * GET /icon - Alias for /icon.svg
   */
  fastify.get('/icon', async (_request: FastifyRequest, reply: FastifyReply) => {
    const iconSvg = getIconSvg();

    if (!iconSvg) {
      return reply.status(404).send({ error: 'Icon not found' });
    }

    reply.header('Content-Type', 'image/svg+xml');
    reply.header('Cache-Control', 'public, max-age=86400');
    return reply.send(iconSvg);
  });

  /**
   * GET /sse - Server-Sent Events endpoint for MCP
   * This establishes a long-lived connection for receiving server-initiated messages
   */
  fastify.get('/sse', async (request: FastifyRequest, reply: FastifyReply) => {
    const gateway = getGateway();
    const session = gateway.createSession();

    log.info({ sessionId: session.id }, 'SSE connection established');

    // Set SSE headers
    reply.raw.setHeader('Content-Type', 'text/event-stream');
    reply.raw.setHeader('Cache-Control', 'no-cache');
    reply.raw.setHeader('Connection', 'keep-alive');
    reply.raw.setHeader('X-Accel-Buffering', 'no'); // Disable nginx buffering

    // Store the connection
    sseConnections.set(session.id, reply);

    // Send the endpoint event with session info
    const endpointData = JSON.stringify({
      endpoint: `/message`,
      sessionId: session.id,
    });
    reply.raw.write(`event: endpoint\ndata: ${endpointData}\n\n`);

    // Keep connection alive with periodic pings
    const pingInterval = setInterval(() => {
      if (reply.raw.writable) {
        reply.raw.write(`: ping\n\n`);
      } else {
        clearInterval(pingInterval);
      }
    }, 30000);

    // Handle connection close
    request.raw.on('close', () => {
      clearInterval(pingInterval);
      sseConnections.delete(session.id);
      gateway.removeSession(session.id);
      log.info({ sessionId: session.id }, 'SSE connection closed');
    });

    // Don't end the response - keep it open for SSE
    return reply;
  });

  /**
   * POST /message - JSON-RPC message endpoint
   * Clients send requests here and receive responses
   */
  fastify.post('/message', async (request: FastifyRequest, reply: FastifyReply) => {
    const sessionId = request.headers['x-session-id'] as string | undefined;

    try {
      // Parse and validate the JSON-RPC request
      const jsonRpcRequest = JsonRpcRequestSchema.parse(request.body);
      
      log.debug(
        { sessionId, method: jsonRpcRequest.method, id: jsonRpcRequest.id },
        'Received JSON-RPC request'
      );

      const gateway = getGateway();
      const response = await gateway.handleRequest(
        jsonRpcRequest as JsonRpcRequest,
        sessionId
      );

      // If there's an active SSE connection, also send the response there
      if (sessionId && sseConnections.has(sessionId)) {
        const sseReply = sseConnections.get(sessionId);
        if (sseReply && sseReply.raw.writable) {
          const eventData = JSON.stringify(response);
          sseReply.raw.write(`event: message\ndata: ${eventData}\n\n`);
        }
      }

      return reply.send(response);
    } catch (error) {
      if (error instanceof z.ZodError) {
        return reply.status(400).send({
          jsonrpc: '2.0',
          id: (request.body as { id?: string | number })?.id || 0,
          error: {
            code: -32600,
            message: 'Invalid Request',
            data: error.errors,
          },
        });
      }

      log.error({ error, sessionId }, 'Failed to process message');

      return reply.status(500).send({
        jsonrpc: '2.0',
        id: (request.body as { id?: string | number })?.id || 0,
        error: {
          code: -32603,
          message: 'Internal error',
          data: error instanceof Error ? error.message : 'Unknown error',
        },
      });
    }
  });

  /**
   * Shared handler for stateless JSON-RPC requests.
   * Used by both /rpc and /sse (POST) endpoints.
   * This allows clients like Claude Cloud that probe endpoints via POST to work correctly.
   */
  const handleStatelessRpc = async (request: FastifyRequest, reply: FastifyReply) => {
    try {
      const jsonRpcRequest = JsonRpcRequestSchema.parse(request.body) as JsonRpcRequest;

      log.debug({ method: jsonRpcRequest.method, id: jsonRpcRequest.id }, 'Received RPC request');

      const gateway = getGateway();
      const response = await gateway.handleRequest(jsonRpcRequest);

      return reply.send(response);
    } catch (error) {
      if (error instanceof z.ZodError) {
        return reply.status(400).send({
          jsonrpc: '2.0',
          id: (request.body as { id?: string | number })?.id || 0,
          error: {
            code: -32600,
            message: 'Invalid Request',
            data: error.errors,
          },
        });
      }

      log.error({ error }, 'Failed to process RPC request');

      return reply.status(500).send({
        jsonrpc: '2.0',
        id: (request.body as { id?: string | number })?.id || 0,
        error: {
          code: -32603,
          message: 'Internal error',
        },
      });
    }
  };

  /**
   * POST /rpc - Alternative JSON-RPC endpoint (direct response)
   * Simpler endpoint that just returns the response directly
   */
  fastify.post('/rpc', handleStatelessRpc);

  /**
   * POST /sse - Handle HTTP POST to SSE endpoint
   * Some clients (like Claude Cloud) probe the SSE endpoint with POST requests
   * before establishing an SSE connection. This allows those clients to work.
   */
  fastify.post('/sse', handleStatelessRpc);

  /**
   * Broadcast a message to all connected SSE clients
   */
  fastify.decorate('broadcastSSE', (event: string, data: unknown) => {
    const message = JSON.stringify(data);
    for (const [sessionId, sseReply] of sseConnections) {
      if (sseReply.raw.writable) {
        sseReply.raw.write(`event: ${event}\ndata: ${message}\n\n`);
      } else {
        sseConnections.delete(sessionId);
      }
    }
  });

  /**
   * Send a message to a specific SSE client
   */
  fastify.decorate('sendSSE', (sessionId: string, event: string, data: unknown) => {
    const sseReply = sseConnections.get(sessionId);
    if (sseReply && sseReply.raw.writable) {
      const message = JSON.stringify(data);
      sseReply.raw.write(`event: ${event}\ndata: ${message}\n\n`);
      return true;
    }
    return false;
  });

  log.info('MCP routes registered');
}

declare module 'fastify' {
  interface FastifyInstance {
    broadcastSSE: (event: string, data: unknown) => void;
    sendSSE: (sessionId: string, event: string, data: unknown) => boolean;
  }
}
