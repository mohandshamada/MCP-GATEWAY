import Fastify from 'fastify';
import cors from '@fastify/cors';
import formbody from '@fastify/formbody';
import { randomUUID } from 'crypto';
import { createGateway, resetGateway } from './core/gateway.js';
import { resetRegistry } from './core/registry.js';
import { resetRouter } from './core/router.js';
import {
  registerAuthMiddleware,
  registerAdminRoutes,
  registerMcpRoutes,
  initializeRateLimiter,
  shutdownRateLimiter,
  rateLimitMiddleware,
  type AuthConfig,
} from './api/index.js';
import { loadConfig, loadAuthTokens, watchConfig, type GatewayConfig } from './utils/config-loader.js';
import { logger } from './utils/logger.js';
import { resolve } from 'path';
import {
  initializePermissions,
  ensureMcpToolDirectories,
} from './utils/permissions.js';
import { initOAuthServer, getOAuthServer, registerOAuthRoutes } from './oauth/index.js';

/**
 * Default configuration path
 */
const DEFAULT_CONFIG_PATH = resolve(process.cwd(), 'config', 'gateway.json');

/**
 * Create and configure the Fastify server
 */
async function createServer(config: GatewayConfig): Promise<ReturnType<typeof Fastify>> {
  const fastify = Fastify({
    logger: false, // We use our own logger
    trustProxy: true, // Trust reverse proxy headers
  });

  // Register CORS
  await fastify.register(cors, {
    origin: true,
    credentials: true,
  });

  // Register form body parser for OAuth token endpoint
  await fastify.register(formbody);

  // Register OAuth routes BEFORE auth middleware (token endpoint must be public)
  if (config.oauthServer?.enabled) {
    registerOAuthRoutes(fastify);
    logger.info(
      { clients: config.oauthServer.clients?.length || 0 },
      'OAuth server routes registered'
    );
  }

  // Initialize and register rate limiting
  if (config.settings.enableRateLimiting) {
    initializeRateLimiter(config.settings.rateLimit);
    fastify.addHook('preHandler', rateLimitMiddleware);
    logger.info(
      {
        windowMs: config.settings.rateLimit.windowMs,
        maxRequests: config.settings.rateLimit.maxRequests,
      },
      'Rate limiting enabled'
    );
  }

  // Configure authentication
  const tokens = loadAuthTokens(config);
  if (config.auth.enabled && tokens.length === 0) {
    logger.warn('Authentication is enabled but no tokens are configured');
  }

  const authConfig: AuthConfig = {
    enabled: config.auth.enabled,
    tokens,
    adminTokens: tokens, // All tokens have admin access by default
  };

  registerAuthMiddleware(fastify, authConfig);

  // Register routes
  await registerMcpRoutes(fastify);
  await registerAdminRoutes(fastify);

  // Issue #6: Request correlation tracking - assign/preserve request ID
  fastify.addHook('onRequest', (request, _reply, done) => {
    // Use existing x-request-id header or generate a new one
    const requestId = (request.headers['x-request-id'] as string) || randomUUID();
    (request as any).requestId = requestId;

    logger.debug(
      {
        method: request.method,
        url: request.url,
        ip: request.ip,
        requestId,
      },
      'Incoming request'
    );
    done();
  });

  // Issue #6: Add request ID to response headers
  fastify.addHook('onResponse', (request, reply, done) => {
    const requestId = (request as any).requestId;
    reply.header('x-request-id', requestId);

    logger.debug(
      {
        method: request.method,
        url: request.url,
        statusCode: reply.statusCode,
        responseTime: reply.elapsedTime,
        requestId,
      },
      'Request completed'
    );
    done();
  });

  // Add error handler with request correlation
  fastify.setErrorHandler((error, request, reply) => {
    const requestId = (request as any).requestId || 'unknown';

    logger.error(
      {
        error,
        method: request.method,
        url: request.url,
        requestId,
      },
      'Request error'
    );

    reply.status(error.statusCode || 500).send({
      error: error.name,
      message: error.message,
      statusCode: error.statusCode || 500,
      requestId,
    });
  });

  return fastify;
}

/**
 * Main application entry point
 */
async function main(): Promise<void> {
  const configPath = process.env.CONFIG_PATH || DEFAULT_CONFIG_PATH;

  logger.info({ configPath }, 'Starting MCP Gateway');

  // Initialize permissions system and check root access
  const permissionInfo = initializePermissions();
  if (!permissionInfo.isRoot && !permissionInfo.hasSudo) {
    logger.warn(
      { recommendations: permissionInfo.recommendations },
      'Running without elevated privileges - some features may be limited'
    );
  } else {
    logger.info(
      { isRoot: permissionInfo.isRoot, hasSudo: permissionInfo.hasSudo },
      'Elevated privileges available'
    );
  }

  // Create MCP tool directories with full permissions (777)
  const mcpDataPath = resolve(process.cwd(), 'mcp-data');
  const dirResult = ensureMcpToolDirectories(mcpDataPath);
  if (!dirResult.success) {
    logger.warn(
      { errors: dirResult.errors },
      'Some MCP directories could not be created with full permissions'
    );
  }

  // Load configuration
  let config: GatewayConfig;
  try {
    config = loadConfig(configPath);
  } catch (error) {
    logger.error({ error, configPath }, 'Failed to load configuration');
    process.exit(1);
  }

  // Initialize OAuth server if enabled
  if (config.oauthServer?.enabled) {
    initOAuthServer({
      enabled: true,
      issuer: config.oauthServer.issuer,
      tokenExpiresIn: config.oauthServer.tokenExpiresIn,
      refreshTokenExpiresIn: config.oauthServer.refreshTokenExpiresIn,
      clients: config.oauthServer.clients,
    });
    logger.info(
      { clients: config.oauthServer.clients?.length || 0 },
      'Built-in OAuth server initialized'
    );
  }

  // Create and initialize the gateway
  const gateway = createGateway(config);
  await gateway.initialize();

  // Create the HTTP server
  const server = await createServer(config);

  // Handle graceful shutdown
  const shutdown = async (signal: string): Promise<void> => {
    logger.info({ signal }, 'Received shutdown signal');

    try {
      await server.close();
      logger.info('HTTP server closed');

      // Stop OAuth server if running
      const oauthServer = getOAuthServer();
      if (oauthServer) {
        oauthServer.stop();
        logger.info('OAuth server stopped');
      }

      shutdownRateLimiter();
      await resetGateway();
      resetRegistry();
      resetRouter();
      logger.info('Gateway shutdown complete');

      process.exit(0);
    } catch (error) {
      logger.error({ error }, 'Error during shutdown');
      process.exit(1);
    }
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  // Handle uncaught errors
  process.on('uncaughtException', (error) => {
    logger.fatal({ error }, 'Uncaught exception');
    process.exit(1);
  });

  process.on('unhandledRejection', (reason) => {
    logger.fatal({ reason }, 'Unhandled rejection');
    process.exit(1);
  });

  // Watch for config changes if enabled
  if (config.settings.enableHotReload) {
    watchConfig(configPath, async (_newConfig) => {
      logger.info('Configuration reloaded');
      // Note: Full hot-reload would require more complex logic
      // For now, we just log the change
    });
  }

  // Start the server
  try {
    const host = config.gateway.host;
    const port = config.gateway.port;

    await server.listen({ port, host });

    logger.info(
      {
        host,
        port,
        servers: config.servers.length,
        authEnabled: config.auth.enabled,
      },
      `🚀 MCP Gateway listening on http://${host}:${port}`
    );

    // Log registered endpoints
    const endpoints = [
      'GET  /sse       - SSE connection endpoint',
      'POST /message   - JSON-RPC message endpoint',
      'POST /rpc       - Direct JSON-RPC endpoint',
      'GET  /admin/status    - Gateway status',
      'GET  /admin/servers   - List servers',
      'POST /admin/servers   - Register server',
      'DELETE /admin/servers/:id - Remove server',
      'GET  /admin/health    - Health check',
    ];

    // Add OAuth endpoints if enabled
    if (config.oauthServer?.enabled) {
      endpoints.push(
        'POST /oauth/token     - OAuth token endpoint',
        'POST /oauth/revoke    - Revoke token',
        'GET  /oauth/info      - OAuth server info',
        'POST /oauth/clients   - Register OAuth client',
        'DELETE /oauth/clients/:id - Remove client',
        'GET  /.well-known/openid-configuration - Discovery'
      );
    }

    logger.info({ endpoints }, 'Available endpoints');
  } catch (error) {
    logger.fatal({ error }, 'Failed to start server');
    process.exit(1);
  }
}

// Run the application
main().catch((error) => {
  logger.fatal({ error }, 'Fatal error');
  process.exit(1);
});
