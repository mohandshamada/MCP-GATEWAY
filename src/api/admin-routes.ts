import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { z } from 'zod';
import { resolve } from 'path';
import { getRegistry } from '../core/registry.js';
import { getGateway } from '../core/gateway.js';
import { validateServerConfig, saveConfig, loadConfig } from '../utils/config-loader.js';
import { createChildLogger, type Logger } from '../utils/logger.js';
import { adminMiddleware } from './auth-middleware.js';
import { getRateLimiterStats } from './rate-limiter.js';
import {
  isRunningAsRoot,
  hasSudoAccess,
  setFilePermissions,
  setPermissionsRecursive,
  createDirectoryWithFullAccess,
  getFilePermissions,
  executeAsRoot,
} from '../utils/permissions.js';

const log: Logger = createChildLogger({ component: 'admin-api' });

/**
 * Issue #4: Error suggestions helper
 * Returns actionable suggestions based on error codes
 */
function getErrorSuggestions(error: NodeJS.ErrnoException): string[] {
  const suggestions: string[] = [];

  if (error.code === 'ENOENT') {
    suggestions.push('Check that the command path is correct');
    suggestions.push('Verify the file/directory exists');
    suggestions.push('Ensure the executable is in your PATH');
  }
  if (error.code === 'EACCES') {
    suggestions.push('Check file permissions');
    suggestions.push('Try running with appropriate privileges');
    suggestions.push('Verify the file is executable (chmod +x)');
  }
  if (error.code === 'ETIMEDOUT') {
    suggestions.push('Increase timeout configuration');
    suggestions.push('Check network connectivity');
    suggestions.push('Verify the server is responding');
  }
  if (error.code === 'ECONNREFUSED') {
    suggestions.push('Verify the server is running');
    suggestions.push('Check host and port configuration');
    suggestions.push('Ensure no firewall is blocking the connection');
  }
  if (error.code === 'EADDRINUSE') {
    suggestions.push('The port is already in use');
    suggestions.push('Try a different port');
    suggestions.push('Stop the conflicting process');
  }

  return suggestions;
}

/**
 * Issue #4: Build detailed error response
 */
function buildErrorDetails(error: unknown): {
  code: string;
  message: string;
  suggestions: string[];
  timestamp: string;
} {
  const errnoError = error as NodeJS.ErrnoException;
  return {
    code: errnoError.code || 'UNKNOWN',
    message: error instanceof Error ? error.message : String(error),
    suggestions: errnoError.code ? getErrorSuggestions(errnoError) : [],
    timestamp: new Date().toISOString(),
  };
}

/**
 * Request schemas
 */
const RegisterServerSchema = z.object({
  id: z.string().min(1),
  transport: z.enum(['stdio', 'sse']),
  command: z.string().optional(),
  args: z.array(z.string()).optional(),
  url: z.string().url().optional(),
  env: z.record(z.string()).optional(),
  enabled: z.boolean().optional(),
  lazyLoad: z.boolean().optional(),
  timeout: z.number().optional(),
  maxRetries: z.number().optional(),
});

const ServerIdParamsSchema = z.object({
  id: z.string().min(1),
});

/**
 * Register admin routes
 */
export async function registerAdminRoutes(fastify: FastifyInstance): Promise<void> {
  // Apply admin middleware to all admin routes
  fastify.addHook('preHandler', adminMiddleware);

  /**
   * GET /admin/status - Get gateway status
   */
  fastify.get('/admin/status', async (_request: FastifyRequest, reply: FastifyReply) => {
    try {
      const gateway = getGateway();
      const status = gateway.getStatus();

      return reply.send({
        success: true,
        data: status,
      });
    } catch (error) {
      log.error({ error }, 'Failed to get status');
      return reply.status(500).send({
        success: false,
        error: 'Failed to get gateway status',
      });
    }
  });

  /**
   * GET /admin/servers - List all servers
   */
  fastify.get('/admin/servers', async (_request: FastifyRequest, reply: FastifyReply) => {
    try {
      const registry = getRegistry();
      const status = registry.getStatus();

      return reply.send({
        success: true,
        data: {
          total: status.totalServers,
          healthy: status.healthyServers,
          unhealthy: status.unhealthyServers,
          servers: status.servers.map((server) => ({
            id: server.id,
            transport: server.transport,
            health: server.health,
            capabilities: {
              tools: server.tools,
              resources: server.resources,
              prompts: server.prompts,
            },
            stats: server.stats,
          })),
        },
      });
    } catch (error) {
      log.error({ error }, 'Failed to list servers');
      return reply.status(500).send({
        success: false,
        error: 'Failed to list servers',
      });
    }
  });

  /**
   * GET /admin/servers/:id - Get server details
   */
  fastify.get<{
    Params: { id: string };
  }>('/admin/servers/:id', async (request: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) => {
    try {
      const { id } = ServerIdParamsSchema.parse(request.params);
      const registry = getRegistry();
      const adapter = registry.getAdapter(id);

      if (!adapter) {
        return reply.status(404).send({
          success: false,
          error: `Server '${id}' not found`,
        });
      }

      const config = adapter.getConfig();
      const capabilities = adapter.getCapabilities();
      const stats = adapter.getStats();

      return reply.send({
        success: true,
        data: {
          id: config.id,
          transport: config.transport,
          health: adapter.getHealth(),
          connected: adapter.isConnected(),
          config: {
            command: config.command,
            args: config.args,
            url: config.url,
            lazyLoad: config.lazyLoad,
            timeout: config.timeout,
            maxRetries: config.maxRetries,
          },
          capabilities: capabilities
            ? {
                tools: capabilities.tools?.map((t) => t.name) || [],
                resources: capabilities.resources?.map((r) => r.uri) || [],
                prompts: capabilities.prompts?.map((p) => p.name) || [],
                serverInfo: capabilities.serverInfo,
              }
            : null,
          stats,
          // Issue #8: Circuit breaker status
          circuitBreaker: adapter.getCircuitBreakerStatus(),
          // Issue #3: Retry state
          retryState: adapter.getRetryState(),
        },
      });
    } catch (error) {
      if (error instanceof z.ZodError) {
        return reply.status(400).send({
          success: false,
          error: 'Invalid parameters',
          details: error.errors,
        });
      }
      log.error({ error }, 'Failed to get server details');
      return reply.status(500).send({
        success: false,
        error: 'Failed to get server details',
      });
    }
  });

  /**
   * POST /admin/servers - Register a new server
   * Also persists to configuration file for restart persistence
   */
  fastify.post('/admin/servers', async (request: FastifyRequest, reply: FastifyReply) => {
    const requestId = (request as any).requestId || 'unknown';

    try {
      const body = RegisterServerSchema.parse(request.body);
      const config = validateServerConfig(body);

      const registry = getRegistry();

      if (registry.hasServer(config.id)) {
        log.warn(
          { serverId: config.id, requestId },
          'Server registration failed: already registered'
        );
        return reply.status(409).send({
          success: false,
          error: `Server '${config.id}' is already registered`,
          requestId,
        });
      }

      log.info(
        { serverId: config.id, transport: config.transport, requestId },
        'Registering new server via API'
      );

      // Register in memory
      await registry.registerServer(config);
      const adapter = registry.getAdapter(config.id);

      // Persist to config file
      let persisted = false;
      let persistError: string | null = null;

      try {
        const configPath = process.env.CONFIG_PATH || resolve(process.cwd(), 'config', 'gateway.json');
        const currentConfig = loadConfig(configPath);

        // Only add if not already in config
        if (!currentConfig.servers.find(s => s.id === config.id)) {
          currentConfig.servers.push(config);
          saveConfig(configPath, currentConfig);
          persisted = true;

          log.info(
            { serverId: config.id, configPath, requestId },
            'Server successfully persisted to configuration file'
          );
        }
      } catch (err) {
        persistError = err instanceof Error ? err.message : String(err);
        log.error(
          { serverId: config.id, persistError, requestId },
          'Warning: Server registered in memory but failed to persist to disk'
        );
        // Continue - server is in-memory even if persistence failed
      }

      return reply.status(201).send({
        success: true,
        message: `Server '${config.id}' registered successfully`,
        data: {
          id: config.id,
          transport: config.transport,
          command: config.command,
          health: adapter?.getHealth() || 'unknown',
          connected: adapter?.isConnected() || false,
          persisted,
          persistError: persistError || null,
        },
        requestId,
      });
    } catch (error) {
      if (error instanceof z.ZodError) {
        log.warn(
          { validationErrors: error.errors, requestId },
          'Server registration failed: validation error'
        );
        return reply.status(400).send({
          success: false,
          error: 'Invalid server configuration',
          details: error.errors.map(e => ({
            path: e.path.join('.'),
            message: e.message,
          })),
          requestId,
        });
      }

      const errorDetails = buildErrorDetails(error);
      log.error(
        { error: errorDetails, requestId },
        'Unexpected error during server registration'
      );
      return reply.status(500).send({
        success: false,
        error: 'Failed to register server',
        details: errorDetails,
        requestId,
      });
    }
  });

  /**
   * DELETE /admin/servers/:id - Unregister a server
   * Also removes from persistent configuration
   */
  fastify.delete<{
    Params: { id: string };
  }>('/admin/servers/:id', async (request: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) => {
    const requestId = (request as any).requestId || 'unknown';

    try {
      const { id } = ServerIdParamsSchema.parse(request.params);
      const registry = getRegistry();

      if (!registry.hasServer(id)) {
        log.warn({ serverId: id, requestId }, 'Server unregistration failed: not found');
        return reply.status(404).send({
          success: false,
          error: `Server '${id}' not found`,
          requestId,
        });
      }

      log.info({ serverId: id, requestId }, 'Unregistering server via API');

      // Unregister from memory
      await registry.unregisterServer(id);

      // Remove from config file
      let persisted = false;
      let persistError: string | null = null;

      try {
        const configPath = process.env.CONFIG_PATH || resolve(process.cwd(), 'config', 'gateway.json');
        const currentConfig = loadConfig(configPath);

        const initialLength = currentConfig.servers.length;
        currentConfig.servers = currentConfig.servers.filter(s => s.id !== id);

        if (currentConfig.servers.length < initialLength) {
          saveConfig(configPath, currentConfig);
          persisted = true;

          log.info(
            { serverId: id, configPath, requestId },
            'Server successfully removed from configuration file'
          );
        }
      } catch (err) {
        persistError = err instanceof Error ? err.message : String(err);
        log.error(
          { serverId: id, persistError, requestId },
          'Warning: Server unregistered from memory but failed to remove from disk'
        );
      }

      return reply.send({
        success: true,
        message: `Server '${id}' unregistered successfully`,
        data: {
          id,
          persisted,
          persistError: persistError || null,
        },
        requestId,
      });
    } catch (error) {
      if (error instanceof z.ZodError) {
        log.warn({ validationErrors: error.errors, requestId }, 'Invalid parameters');
        return reply.status(400).send({
          success: false,
          error: 'Invalid parameters',
          details: error.errors,
          requestId,
        });
      }

      log.error(
        { error: error instanceof Error ? error.message : String(error), requestId },
        'Failed to unregister server'
      );
      return reply.status(500).send({
        success: false,
        error: error instanceof Error ? error.message : 'Failed to unregister server',
        requestId,
      });
    }
  });

  /**
   * POST /admin/servers/:id/restart - Restart a server
   */
  fastify.post<{
    Params: { id: string };
  }>('/admin/servers/:id/restart', async (request: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) => {
    try {
      const { id } = ServerIdParamsSchema.parse(request.params);
      const registry = getRegistry();
      const adapter = registry.getAdapter(id);

      if (!adapter) {
        return reply.status(404).send({
          success: false,
          error: `Server '${id}' not found`,
        });
      }

      log.info({ serverId: id }, 'Restarting server via API');

      await adapter.stop();
      await adapter.start();

      return reply.send({
        success: true,
        message: `Server '${id}' restarted successfully`,
        data: {
          health: adapter.getHealth(),
          connected: adapter.isConnected(),
        },
      });
    } catch (error) {
      if (error instanceof z.ZodError) {
        return reply.status(400).send({
          success: false,
          error: 'Invalid parameters',
          details: error.errors,
        });
      }
      log.error({ error }, 'Failed to restart server');
      return reply.status(500).send({
        success: false,
        error: error instanceof Error ? error.message : 'Failed to restart server',
      });
    }
  });

  /**
   * GET /admin/tools - List all namespaced tools
   */
  fastify.get('/admin/tools', async (_request: FastifyRequest, reply: FastifyReply) => {
    try {
      const registry = getRegistry();
      const { tools } = registry.getMergedCapabilities();

      return reply.send({
        success: true,
        data: {
          total: tools.length,
          tools: tools.map(({ serverId, tool }) => ({
            namespacedName: `${serverId}__${tool.name}`,
            serverId,
            originalName: tool.name,
            description: tool.description,
          })),
        },
      });
    } catch (error) {
      log.error({ error }, 'Failed to list tools');
      return reply.status(500).send({
        success: false,
        error: 'Failed to list tools',
      });
    }
  });

  /**
   * GET /admin/health - Health check endpoint
   */
  fastify.get('/admin/health', async (_request: FastifyRequest, reply: FastifyReply) => {
    try {
      const registry = getRegistry();
      const status = registry.getStatus();

      const isHealthy = status.healthyServers > 0 || status.totalServers === 0;

      return reply.status(isHealthy ? 200 : 503).send({
        status: isHealthy ? 'healthy' : 'unhealthy',
        timestamp: new Date().toISOString(),
        servers: {
          total: status.totalServers,
          healthy: status.healthyServers,
          unhealthy: status.unhealthyServers,
        },
      });
    } catch (error) {
      log.error({ error }, 'Health check failed');
      return reply.status(503).send({
        status: 'unhealthy',
        timestamp: new Date().toISOString(),
        error: 'Health check failed',
      });
    }
  });

  /**
   * GET /admin/metrics - Get gateway metrics for monitoring
   */
  fastify.get('/admin/metrics', async (_request: FastifyRequest, reply: FastifyReply) => {
    try {
      const gateway = getGateway();
      const registry = getRegistry();
      const gatewayStatus = gateway.getStatus();
      const registryStatus = registry.getStatus();
      const rateLimitStats = getRateLimiterStats();

      // Calculate aggregate stats
      const aggregateStats = registryStatus.servers.reduce(
        (acc, server) => {
          acc.totalRequests += server.stats.requestCount;
          acc.totalErrors += server.stats.errorCount;
          acc.totalUptime += server.stats.uptime;
          if (server.stats.avgResponseTime > 0) {
            acc.avgResponseTimes.push(server.stats.avgResponseTime);
          }
          return acc;
        },
        {
          totalRequests: 0,
          totalErrors: 0,
          totalUptime: 0,
          avgResponseTimes: [] as number[],
        }
      );

      const avgResponseTime =
        aggregateStats.avgResponseTimes.length > 0
          ? aggregateStats.avgResponseTimes.reduce((a, b) => a + b, 0) /
            aggregateStats.avgResponseTimes.length
          : 0;

      return reply.send({
        timestamp: new Date().toISOString(),
        gateway: {
          initialized: gatewayStatus.initialized,
          activeSessions: gatewayStatus.sessions,
        },
        servers: {
          total: registryStatus.totalServers,
          healthy: registryStatus.healthyServers,
          unhealthy: registryStatus.unhealthyServers,
          starting: registryStatus.startingServers,
          stopped: registryStatus.stoppedServers,
        },
        requests: {
          total: aggregateStats.totalRequests,
          errors: aggregateStats.totalErrors,
          errorRate:
            aggregateStats.totalRequests > 0
              ? (aggregateStats.totalErrors / aggregateStats.totalRequests) * 100
              : 0,
          avgResponseTimeMs: Math.round(avgResponseTime * 100) / 100,
        },
        rateLimit: rateLimitStats || {
          enabled: false,
        },
        memory: {
          heapUsedMB: Math.round((process.memoryUsage().heapUsed / 1024 / 1024) * 100) / 100,
          heapTotalMB: Math.round((process.memoryUsage().heapTotal / 1024 / 1024) * 100) / 100,
          rssMB: Math.round((process.memoryUsage().rss / 1024 / 1024) * 100) / 100,
        },
        uptime: {
          seconds: Math.round(process.uptime()),
          formatted: formatUptime(process.uptime()),
        },
      });
    } catch (error) {
      log.error({ error }, 'Failed to get metrics');
      return reply.status(500).send({
        success: false,
        error: 'Failed to get metrics',
      });
    }
  });

  /**
   * GET /admin/permissions - Get current permission status
   */
  fastify.get('/admin/permissions', async (_request: FastifyRequest, reply: FastifyReply) => {
    try {
      return reply.send({
        success: true,
        data: {
          isRoot: isRunningAsRoot(),
          hasSudo: hasSudoAccess(),
          uid: process.getuid?.() ?? null,
          gid: process.getgid?.() ?? null,
          platform: process.platform,
          recommendations: !isRunningAsRoot() && !hasSudoAccess()
            ? [
                'Run with sudo for full file system access',
                'Configure passwordless sudo for automated operations',
                'Some MCP tools may have limited functionality',
              ]
            : [],
        },
      });
    } catch (error) {
      log.error({ error }, 'Failed to get permission status');
      return reply.status(500).send({
        success: false,
        error: 'Failed to get permission status',
      });
    }
  });

  /**
   * POST /admin/permissions/set - Set file/directory permissions
   */
  fastify.post('/admin/permissions/set', async (request: FastifyRequest, reply: FastifyReply) => {
    const requestId = (request as any).requestId || 'unknown';

    try {
      const schema = z.object({
        path: z.string().min(1),
        mode: z.number().min(0).max(0o777).optional().default(0o777),
        recursive: z.boolean().optional().default(false),
      });

      const { path: targetPath, mode, recursive } = schema.parse(request.body);

      log.info(
        { targetPath, mode: mode.toString(8), recursive, requestId },
        'Setting file permissions'
      );

      let result;
      if (recursive) {
        result = setPermissionsRecursive(targetPath, mode);
      } else {
        result = setFilePermissions(targetPath, mode);
      }

      if (!result.success) {
        return reply.status(400).send({
          success: false,
          error: result.error,
          requestId,
        });
      }

      // Get updated permissions
      const currentPerms = getFilePermissions(targetPath);

      return reply.send({
        success: true,
        message: `Permissions set successfully`,
        data: {
          path: targetPath,
          mode: mode.toString(8),
          recursive,
          current: currentPerms,
        },
        requestId,
      });
    } catch (error) {
      if (error instanceof z.ZodError) {
        return reply.status(400).send({
          success: false,
          error: 'Invalid parameters',
          details: error.errors,
        });
      }
      log.error({ error }, 'Failed to set permissions');
      return reply.status(500).send({
        success: false,
        error: error instanceof Error ? error.message : 'Failed to set permissions',
      });
    }
  });

  /**
   * POST /admin/permissions/mkdir - Create directory with full permissions
   */
  fastify.post('/admin/permissions/mkdir', async (request: FastifyRequest, reply: FastifyReply) => {
    const requestId = (request as any).requestId || 'unknown';

    try {
      const schema = z.object({
        path: z.string().min(1),
      });

      const { path: targetPath } = schema.parse(request.body);

      log.info({ targetPath, requestId }, 'Creating directory with full permissions');

      const result = createDirectoryWithFullAccess(targetPath);

      if (!result.success) {
        return reply.status(400).send({
          success: false,
          error: result.error,
          requestId,
        });
      }

      return reply.status(201).send({
        success: true,
        message: `Directory created with secure permissions (755)`,
        data: {
          path: targetPath,
          mode: '755',
        },
        requestId,
      });
    } catch (error) {
      if (error instanceof z.ZodError) {
        return reply.status(400).send({
          success: false,
          error: 'Invalid parameters',
          details: error.errors,
        });
      }
      log.error({ error }, 'Failed to create directory');
      return reply.status(500).send({
        success: false,
        error: error instanceof Error ? error.message : 'Failed to create directory',
      });
    }
  });

  /**
   * POST /admin/permissions/exec - Execute command with elevated privileges
   */
  fastify.post('/admin/permissions/exec', async (request: FastifyRequest, reply: FastifyReply) => {
    const requestId = (request as any).requestId || 'unknown';

    try {
      const schema = z.object({
        command: z.string().min(1),
        cwd: z.string().optional(),
        timeout: z.number().min(1000).max(300000).optional().default(30000),
      });

      const { command, cwd, timeout } = schema.parse(request.body);

      // Security: Whitelist allowed commands (safer than blacklist)
      const allowedCommands = [
        /^ls(\s|$)/,                    // list directory
        /^cat\s+/,                      // read file
        /^head\s+/,                     // read file head
        /^tail\s+/,                     // read file tail
        /^pwd$/,                        // print working directory
        /^whoami$/,                     // current user
        /^id$/,                         // user id info
        /^uname(\s|$)/,                 // system info
        /^df(\s|$)/,                    // disk free
        /^du(\s|$)/,                    // disk usage
        /^free(\s|$)/,                  // memory info
        /^ps(\s|$)/,                    // process status
        /^top\s+-bn1/,                  // one-shot top
        /^uptime$/,                     // system uptime
        /^date$/,                       // current date
        /^echo\s+/,                     // echo (no redirects)
        /^mkdir\s+-p?\s+/,              // create directory
        /^cp\s+/,                       // copy files
        /^mv\s+/,                       // move files
        /^touch\s+/,                    // create/update file
        /^chmod\s+[0-7]{3,4}\s+/,       // change permissions (numeric only)
        /^chown\s+[\w:-]+\s+/,          // change ownership
        /^find\s+/,                     // find files
        /^grep\s+/,                     // search in files
        /^wc(\s|$)/,                    // word count
        /^sort(\s|$)/,                  // sort
        /^uniq(\s|$)/,                  // unique
        /^file\s+/,                     // file type
        /^stat\s+/,                     // file stats
        /^realpath\s+/,                 // resolve path
        /^basename\s+/,                 // base name
        /^dirname\s+/,                  // directory name
        /^npm\s+(install|ci|run|test|build)/, // npm commands
        /^node\s+/,                     // node commands
        /^systemctl\s+(status|is-active|show)/, // systemctl read-only
        /^journalctl(\s|$)/,            // read logs
      ];

      // Additional security: Block dangerous patterns even in allowed commands
      const dangerousPatterns = [
        /[;&|`$()]|>\s*\/|>>/,          // shell metacharacters, redirects to root
        /\brm\b/,                       // rm anywhere
        /\bsudo\b/,                     // sudo in command (we add it ourselves)
        /\beval\b/,                     // eval
        /\bexec\b/,                     // exec
        /\bsource\b/,                   // source
        /\bcurl\b.*\|\s*(ba)?sh/,       // curl pipe to shell
        /\bwget\b.*\|\s*(ba)?sh/,       // wget pipe to shell
        /\/etc\/passwd/,                // password file
        /\/etc\/shadow/,                // shadow file
        /\.ssh\//,                      // ssh directory
        /\bkill\b/,                     // kill processes
        /\bpkill\b/,                    // pkill processes
        /\bkillall\b/,                  // killall
        /\breboot\b/,                   // reboot
        /\bshutdown\b/,                 // shutdown
        /\binit\s+[06]/,                // init halt/reboot
        /\bmkfs\b/,                     // filesystem formatting
        /\bdd\b/,                       // disk copy
        /\bformat\b/,                   // format
      ];

      // Check for dangerous patterns first
      for (const pattern of dangerousPatterns) {
        if (pattern.test(command)) {
          log.warn({ command, requestId, pattern: pattern.source }, 'Blocked dangerous command pattern');
          return reply.status(403).send({
            success: false,
            error: 'Command contains blocked pattern for security reasons',
            requestId,
          });
        }
      }

      // Check if command matches whitelist
      const isAllowed = allowedCommands.some(pattern => pattern.test(command));
      if (!isAllowed) {
        log.warn({ command, requestId }, 'Command not in whitelist');
        return reply.status(403).send({
          success: false,
          error: 'Command not allowed. Only specific safe commands are permitted.',
          allowedCommands: [
            'ls, cat, head, tail, pwd, whoami, id',
            'uname, df, du, free, ps, uptime, date',
            'mkdir, cp, mv, touch, chmod, chown',
            'find, grep, wc, sort, uniq, file, stat',
            'npm (install|ci|run|test|build), node',
            'systemctl (status|is-active|show), journalctl',
          ],
          requestId,
        });
      }

      log.info({ command, cwd, timeout, requestId }, 'Executing command with elevated privileges');

      const result = executeAsRoot(command, { cwd, timeout });

      if (!result.success) {
        return reply.status(400).send({
          success: false,
          error: result.error,
          requestId,
        });
      }

      return reply.send({
        success: true,
        data: {
          output: result.output,
          executedAs: isRunningAsRoot() ? 'root' : hasSudoAccess() ? 'sudo' : 'user',
        },
        requestId,
      });
    } catch (error) {
      if (error instanceof z.ZodError) {
        return reply.status(400).send({
          success: false,
          error: 'Invalid parameters',
          details: error.errors,
        });
      }
      log.error({ error }, 'Failed to execute command');
      return reply.status(500).send({
        success: false,
        error: error instanceof Error ? error.message : 'Failed to execute command',
      });
    }
  });

  /**
   * GET /admin/client-config - Generate client configuration for Claude app integration
   */
  fastify.get('/admin/client-config', async (_request: FastifyRequest, reply: FastifyReply) => {
    try {
      const registry = getRegistry();
      const { tools } = registry.getMergedCapabilities();
      const status = registry.getStatus();

      // Load current config to get domain settings
      const configPath = process.env.CONFIG_PATH || resolve(process.cwd(), 'config', 'gateway.json');
      const currentConfig = loadConfig(configPath);

      // Determine the base URL
      const domain = currentConfig.domain?.domain;
      const publicUrl = currentConfig.domain?.publicUrl;
      const baseUrl = publicUrl || (domain ? `https://${domain}` : `http://${currentConfig.gateway.host}:${currentConfig.gateway.port}`);

      // Build capability list
      const serverCapabilities = status.servers.map(s => ({
        id: s.id,
        tools: s.tools,
        healthy: s.health === 'healthy',
      }));

      // Generate Claude Desktop config
      const claudeDesktopConfig = {
        mcpServers: {
          'mcp-gateway': {
            url: `${baseUrl}/sse`,
            transport: 'sse',
            headers: {
              Authorization: 'Bearer YOUR_TOKEN_HERE',
            },
          },
        },
      };

      // Generate SSE client config
      const sseClientConfig = {
        name: currentConfig.gateway.name || 'MCP Gateway',
        version: currentConfig.gateway.version || '1.0.0',
        endpoint: `${baseUrl}/sse`,
        rpcEndpoint: `${baseUrl}/rpc`,
        messageEndpoint: `${baseUrl}/message`,
        transport: 'sse',
        authentication: currentConfig.auth.oauth?.enabled
          ? {
              type: 'oauth2',
              clientId: currentConfig.auth.oauth.clientId,
              issuer: currentConfig.auth.oauth.issuer,
              authorizationUrl: currentConfig.auth.oauth.authorizationUrl,
              tokenUrl: currentConfig.auth.oauth.tokenUrl,
              scopes: currentConfig.auth.oauth.scopes,
            }
          : {
              type: 'bearer',
              header: 'Authorization',
              prefix: 'Bearer',
            },
        capabilities: {
          totalTools: tools.length,
          servers: serverCapabilities,
        },
      };

      // Generate curl examples
      const curlExamples = {
        healthCheck: `curl -H "Authorization: Bearer YOUR_TOKEN" ${baseUrl}/admin/health`,
        listTools: `curl -H "Authorization: Bearer YOUR_TOKEN" ${baseUrl}/admin/tools`,
        listServers: `curl -H "Authorization: Bearer YOUR_TOKEN" ${baseUrl}/admin/servers`,
        sseConnect: `curl -N -H "Authorization: Bearer YOUR_TOKEN" -H "Accept: text/event-stream" ${baseUrl}/sse`,
      };

      return reply.send({
        success: true,
        data: {
          baseUrl,
          domain: domain || null,
          ssl: currentConfig.domain?.ssl?.enabled ?? (baseUrl.startsWith('https')),
          oauth: {
            enabled: currentConfig.auth.oauth?.enabled ?? false,
            clientId: currentConfig.auth.oauth?.clientId || null,
            issuer: currentConfig.auth.oauth?.issuer || null,
          },
          configurations: {
            claudeDesktop: claudeDesktopConfig,
            sseClient: sseClientConfig,
          },
          curlExamples,
          instructions: {
            claudeDesktop: [
              '1. Open Claude Desktop settings',
              '2. Navigate to MCP Servers section',
              '3. Add the configuration from "claudeDesktop" above',
              '4. Replace YOUR_TOKEN_HERE with your actual API token',
              '5. Restart Claude Desktop',
            ],
            programmatic: [
              '1. Connect to the SSE endpoint for real-time communication',
              '2. Send JSON-RPC requests to the /message endpoint with X-Session-ID header',
              '3. Or use the /rpc endpoint for stateless JSON-RPC calls',
              '4. All requests require Authorization header with Bearer token',
            ],
          },
        },
      });
    } catch (error) {
      log.error({ error }, 'Failed to generate client config');
      return reply.status(500).send({
        success: false,
        error: 'Failed to generate client configuration',
      });
    }
  });

  /**
   * GET /admin/client-config/claude - Generate Claude Desktop specific config file
   */
  fastify.get('/admin/client-config/claude', async (request: FastifyRequest, reply: FastifyReply) => {
    try {
      const configPath = process.env.CONFIG_PATH || resolve(process.cwd(), 'config', 'gateway.json');
      const currentConfig = loadConfig(configPath);

      const domain = currentConfig.domain?.domain;
      const publicUrl = currentConfig.domain?.publicUrl;
      const baseUrl = publicUrl || (domain ? `https://${domain}` : `http://${currentConfig.gateway.host}:${currentConfig.gateway.port}`);

      // Get token from request header to include in config
      const authHeader = request.headers.authorization;
      const token = authHeader?.startsWith('Bearer ') ? authHeader.slice(7) : 'YOUR_TOKEN_HERE';

      const claudeConfig = {
        mcpServers: {
          'mcp-gateway': {
            url: `${baseUrl}/sse`,
            transport: 'sse',
            headers: {
              Authorization: `Bearer ${token}`,
            },
          },
        },
      };

      reply.header('Content-Type', 'application/json');
      reply.header('Content-Disposition', 'attachment; filename="claude_desktop_config.json"');

      return reply.send(claudeConfig);
    } catch (error) {
      log.error({ error }, 'Failed to generate Claude config');
      return reply.status(500).send({
        success: false,
        error: 'Failed to generate Claude Desktop configuration',
      });
    }
  });

  log.info('Admin routes registered');
}

/**
 * Format uptime in human-readable format
 */
function formatUptime(seconds: number): string {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = Math.floor(seconds % 60);

  const parts: string[] = [];
  if (days > 0) parts.push(`${days}d`);
  if (hours > 0) parts.push(`${hours}h`);
  if (minutes > 0) parts.push(`${minutes}m`);
  parts.push(`${secs}s`);

  return parts.join(' ');
}
