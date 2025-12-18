import { EventEmitter } from 'events';
import { v4 as uuidv4 } from 'uuid';
import { getRegistry, type Registry } from './registry.js';
import {
  getRouter,
  type Router,
  NAMESPACE_SEPARATOR,
  type NamespacedTool,
  type NamespacedResource,
  type NamespacedPrompt,
} from './router.js';
import { type JsonRpcRequest, type JsonRpcResponse } from '../adapters/index.js';
import type { GatewayConfig } from '../utils/config-loader.js';
import { createChildLogger, generateCorrelationId, type Logger } from '../utils/logger.js';

/**
 * MCP Protocol version
 */
const PROTOCOL_VERSION = '2024-11-05';

/**
 * Session information for SSE connections
 */
export interface Session {
  id: string;
  createdAt: Date;
  lastActivity: Date;
  clientInfo?: {
    name: string;
    version: string;
  };
}

/**
 * Gateway capabilities advertised to clients
 */
export interface GatewayCapabilities {
  tools?: Record<string, unknown>;
  resources?: Record<string, unknown>;
  prompts?: Record<string, unknown>;
}

/**
 * The main MCP Gateway facade
 */
export class Gateway extends EventEmitter {
  private readonly config: GatewayConfig;
  private readonly registry: Registry;
  private readonly router: Router;
  private readonly log: Logger;
  private readonly sessions: Map<string, Session> = new Map();
  private isInitialized: boolean = false;
  private sessionCleanupInterval: NodeJS.Timeout | null = null;

  constructor(config: GatewayConfig, registry?: Registry, router?: Router) {
    super();
    this.config = config;
    this.registry = registry || getRegistry();
    this.router = router || getRouter();
    this.log = createChildLogger({ component: 'gateway' });
  }

  /**
   * Initialize the gateway
   */
  async initialize(): Promise<void> {
    if (this.isInitialized) {
      return;
    }

    this.log.info('Initializing gateway');

    // Register all configured servers
    await this.registry.registerServers(this.config.servers);

    // Start health checks if enabled
    if (this.config.settings.enableHealthChecks) {
      this.registry.startHealthChecks(this.config.settings.healthCheckInterval);
    }

    // Start session cleanup
    this.startSessionCleanup();

    this.isInitialized = true;
    this.log.info('Gateway initialized');
  }

  /**
   * Start periodic session cleanup
   */
  private startSessionCleanup(): void {
    const sessionTimeout = this.config.settings.sessionTimeout;
    // Run cleanup every minute
    const cleanupInterval = Math.min(sessionTimeout / 2, 60000);

    this.sessionCleanupInterval = setInterval(() => {
      this.cleanupStaleSessions();
    }, cleanupInterval);

    this.log.info({ sessionTimeout, cleanupInterval }, 'Session cleanup started');
  }

  /**
   * Clean up sessions that have been inactive for too long
   */
  private cleanupStaleSessions(): void {
    const now = Date.now();
    const timeout = this.config.settings.sessionTimeout;
    let cleaned = 0;

    for (const [sessionId, session] of this.sessions) {
      const inactiveTime = now - session.lastActivity.getTime();
      if (inactiveTime > timeout) {
        this.sessions.delete(sessionId);
        this.emit('session:expired', sessionId);
        cleaned++;
      }
    }

    if (cleaned > 0) {
      this.log.info({ cleaned, remaining: this.sessions.size }, 'Cleaned up stale sessions');
    }
  }

  /**
   * Stop session cleanup
   */
  private stopSessionCleanup(): void {
    if (this.sessionCleanupInterval) {
      clearInterval(this.sessionCleanupInterval);
      this.sessionCleanupInterval = null;
      this.log.info('Session cleanup stopped');
    }
  }

  /**
   * Create a new session
   */
  createSession(clientInfo?: { name: string; version: string }): Session {
    const session: Session = {
      id: uuidv4(),
      createdAt: new Date(),
      lastActivity: new Date(),
      clientInfo,
    };

    this.sessions.set(session.id, session);
    this.log.info({ sessionId: session.id, clientInfo }, 'Session created');

    return session;
  }

  /**
   * Get a session by ID
   */
  getSession(sessionId: string): Session | undefined {
    return this.sessions.get(sessionId);
  }

  /**
   * Update session activity
   */
  touchSession(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (session) {
      session.lastActivity = new Date();
    }
  }

  /**
   * Remove a session
   */
  removeSession(sessionId: string): void {
    this.sessions.delete(sessionId);
    this.log.info({ sessionId }, 'Session removed');
  }

  /**
   * Handle an incoming JSON-RPC request
   */
  async handleRequest(request: JsonRpcRequest, sessionId?: string): Promise<JsonRpcResponse> {
    const correlationId = generateCorrelationId();
    const log = this.log.child({ correlationId, method: request.method, sessionId });

    log.info({ params: request.params }, 'Handling request');

    if (sessionId) {
      this.touchSession(sessionId);
    }

    try {
      const response = await this.routeMethod(request, sessionId);
      log.info({ hasError: !!response.error }, 'Request completed');
      return response;
    } catch (error) {
      log.error({ error }, 'Request failed');
      return {
        jsonrpc: '2.0',
        id: request.id,
        error: {
          code: -32603,
          message: error instanceof Error ? error.message : 'Internal error',
          data: { correlationId },
        },
      };
    }
  }

  /**
   * Route a method to the appropriate handler
   */
  private async routeMethod(
    request: JsonRpcRequest,
    _sessionId?: string
  ): Promise<JsonRpcResponse> {
    const { method, params, id } = request;

    switch (method) {
      case 'initialize':
        return this.handleInitialize(id, params);

      case 'ping':
        return { jsonrpc: '2.0', id, result: {} };

      case 'tools/list':
        return this.handleToolsList(id);

      case 'tools/call':
        return this.handleToolsCall(id, params);

      case 'resources/list':
        return this.handleResourcesList(id);

      case 'resources/read':
        return this.handleResourcesRead(id, params);

      case 'resources/templates/list':
        return this.handleResourcesTemplatesList(id);

      case 'prompts/list':
        return this.handlePromptsList(id);

      case 'prompts/get':
        return this.handlePromptsGet(id, params);

      case 'notifications/initialized':
      case 'notifications/cancelled':
        // Notifications don't require a response, but we acknowledge them
        return { jsonrpc: '2.0', id, result: {} };

      default:
        return {
          jsonrpc: '2.0',
          id,
          error: {
            code: -32601,
            message: `Method not found: ${method}`,
          },
        };
    }
  }

  /**
   * Handle initialize request
   */
  private async handleInitialize(
    id: string | number,
    _params: unknown
  ): Promise<JsonRpcResponse> {
    // Determine which capabilities we have based on registered servers
    const capabilities = this.registry.getMergedCapabilities();
    const gatewayCapabilities: GatewayCapabilities = {};

    if (capabilities.tools.length > 0) {
      gatewayCapabilities.tools = {};
    }

    if (capabilities.resources.length > 0) {
      gatewayCapabilities.resources = {};
    }

    if (capabilities.prompts.length > 0) {
      gatewayCapabilities.prompts = {};
    }

    // Build the icon URL based on configuration
    let iconUrl: string | undefined;
    if (this.config.domain?.publicUrl) {
      iconUrl = `${this.config.domain.publicUrl}/icon.svg`;
    } else if (this.config.domain?.domain) {
      const protocol = this.config.domain.ssl?.enabled ? 'https' : 'http';
      iconUrl = `${protocol}://${this.config.domain.domain}/icon.svg`;
    }

    // Build serverInfo with optional iconUrl
    const serverInfo: Record<string, string> = {
      name: this.config.gateway.name,
      version: this.config.gateway.version,
    };

    if (iconUrl) {
      serverInfo.iconUrl = iconUrl;
    }

    return {
      jsonrpc: '2.0',
      id,
      result: {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: gatewayCapabilities,
        serverInfo,
        instructions: `This is a federated MCP gateway. Tools, resources, and prompts are namespaced with server IDs using the format: serverId${NAMESPACE_SEPARATOR}name. Available servers: ${this.registry.getServerIds().join(', ')}`,
      },
    };
  }

  /**
   * Handle tools/list request
   */
  private async handleToolsList(id: string | number): Promise<JsonRpcResponse> {
    const tools: NamespacedTool[] = this.router.getNamespacedTools();

    // Strip internal fields before sending
    const sanitizedTools = tools.map(({ _serverId, _originalName, ...tool }) => tool);

    return {
      jsonrpc: '2.0',
      id,
      result: {
        tools: sanitizedTools,
      },
    };
  }

  /**
   * Handle tools/call request
   */
  private async handleToolsCall(
    id: string | number,
    params: unknown
  ): Promise<JsonRpcResponse> {
    const callParams = params as {
      name: string;
      arguments?: Record<string, unknown>;
    };

    if (!callParams.name) {
      return {
        jsonrpc: '2.0',
        id,
        error: {
          code: -32602,
          message: 'Missing required parameter: name',
        },
      };
    }

    const response = await this.router.routeToolCall(
      callParams.name,
      callParams.arguments || {}
    );

    // Preserve the original request ID
    return {
      ...response,
      id,
    };
  }

  /**
   * Handle resources/list request
   */
  private async handleResourcesList(id: string | number): Promise<JsonRpcResponse> {
    const resources: NamespacedResource[] = this.router.getNamespacedResources();

    // Strip internal fields before sending
    const sanitizedResources = resources.map(
      ({ _serverId, _originalUri, ...resource }) => resource
    );

    return {
      jsonrpc: '2.0',
      id,
      result: {
        resources: sanitizedResources,
      },
    };
  }

  /**
   * Handle resources/read request
   */
  private async handleResourcesRead(
    id: string | number,
    params: unknown
  ): Promise<JsonRpcResponse> {
    const readParams = params as { uri: string };

    if (!readParams.uri) {
      return {
        jsonrpc: '2.0',
        id,
        error: {
          code: -32602,
          message: 'Missing required parameter: uri',
        },
      };
    }

    const response = await this.router.routeResourceRead(readParams.uri);

    return {
      ...response,
      id,
    };
  }

  /**
   * Handle resources/templates/list request
   */
  private async handleResourcesTemplatesList(
    id: string | number
  ): Promise<JsonRpcResponse> {
    // Resource templates are not currently aggregated
    return {
      jsonrpc: '2.0',
      id,
      result: {
        resourceTemplates: [],
      },
    };
  }

  /**
   * Handle prompts/list request
   */
  private async handlePromptsList(id: string | number): Promise<JsonRpcResponse> {
    const prompts: NamespacedPrompt[] = this.router.getNamespacedPrompts();

    // Strip internal fields before sending
    const sanitizedPrompts = prompts.map(
      ({ _serverId, _originalName, ...prompt }) => prompt
    );

    return {
      jsonrpc: '2.0',
      id,
      result: {
        prompts: sanitizedPrompts,
      },
    };
  }

  /**
   * Handle prompts/get request
   */
  private async handlePromptsGet(
    id: string | number,
    params: unknown
  ): Promise<JsonRpcResponse> {
    const getParams = params as {
      name: string;
      arguments?: Record<string, unknown>;
    };

    if (!getParams.name) {
      return {
        jsonrpc: '2.0',
        id,
        error: {
          code: -32602,
          message: 'Missing required parameter: name',
        },
      };
    }

    const response = await this.router.routePromptGet(
      getParams.name,
      getParams.arguments
    );

    return {
      ...response,
      id,
    };
  }

  /**
   * Get gateway status
   */
  getStatus(): {
    initialized: boolean;
    sessions: number;
    registry: ReturnType<Registry['getStatus']>;
  } {
    return {
      initialized: this.isInitialized,
      sessions: this.sessions.size,
      registry: this.registry.getStatus(),
    };
  }

  /**
   * Shutdown the gateway
   */
  async shutdown(): Promise<void> {
    this.log.info('Shutting down gateway');

    // Stop session cleanup
    this.stopSessionCleanup();

    // Clear all sessions
    this.sessions.clear();

    // Shutdown the registry
    await this.registry.shutdown();

    this.isInitialized = false;
    this.log.info('Gateway shutdown complete');
  }
}

// Singleton instance
let gatewayInstance: Gateway | null = null;

export function createGateway(config: GatewayConfig): Gateway {
  if (gatewayInstance) {
    throw new Error('Gateway already exists. Call resetGateway() first.');
  }
  gatewayInstance = new Gateway(config);
  return gatewayInstance;
}

export function getGateway(): Gateway {
  if (!gatewayInstance) {
    throw new Error('Gateway not initialized. Call createGateway() first.');
  }
  return gatewayInstance;
}

export function resetGateway(): Promise<void> {
  if (gatewayInstance) {
    const promise = gatewayInstance.shutdown();
    gatewayInstance = null;
    return promise;
  }
  return Promise.resolve();
}
