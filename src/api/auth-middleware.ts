import type { FastifyRequest, FastifyReply, FastifyInstance, HookHandlerDoneFunction } from 'fastify';
import { createChildLogger, type Logger } from '../utils/logger.js';
import { getOAuthServer } from '../oauth/oauth-server.js';

/**
 * Auth middleware configuration
 */
export interface AuthConfig {
  enabled: boolean;
  tokens: string[];
  adminTokens?: string[];
}

/**
 * Extended request with auth info
 */
declare module 'fastify' {
  interface FastifyRequest {
    authToken?: string;
    isAdmin?: boolean;
  }
}

let authConfig: AuthConfig | null = null;
const log: Logger = createChildLogger({ component: 'auth' });

/**
 * Configure authentication
 */
export function configureAuth(config: AuthConfig): void {
  authConfig = config;
  log.info({ enabled: config.enabled, tokenCount: config.tokens.length }, 'Auth configured');
}

/**
 * Extract bearer token from authorization header
 */
function extractBearerToken(authHeader: string | undefined): string | null {
  if (!authHeader) {
    return null;
  }

  const parts = authHeader.split(' ');
  if (parts.length !== 2 || parts[0].toLowerCase() !== 'bearer') {
    return null;
  }

  return parts[1];
}

/**
 * Validate a token against configured tokens and OAuth server
 */
function validateToken(token: string): { valid: boolean; isAdmin: boolean } {
  if (!authConfig) {
    return { valid: false, isAdmin: false };
  }

  // Check admin tokens first
  if (authConfig.adminTokens?.includes(token)) {
    return { valid: true, isAdmin: true };
  }

  // Check regular tokens
  if (authConfig.tokens.includes(token)) {
    return { valid: true, isAdmin: false };
  }

  // Check OAuth server tokens
  const oauthServer = getOAuthServer();
  if (oauthServer) {
    const tokenInfo = oauthServer.validateToken(token);
    if (tokenInfo) {
      // Check if token has admin scope
      const isAdmin = tokenInfo.scopes.includes('mcp:admin');
      return { valid: true, isAdmin };
    }
  }

  return { valid: false, isAdmin: false };
}

/**
 * Extract token from URL query parameter
 * Supports ?token=xxx format for clients that cannot set custom headers
 * (e.g., Claude Cloud "Add custom connector" dialog)
 */
function extractQueryToken(query: unknown): string | null {
  if (typeof query === 'object' && query !== null && 'token' in query) {
    const token = (query as Record<string, unknown>).token;
    if (typeof token === 'string' && token.length > 0) {
      return token;
    }
  }
  return null;
}

/**
 * Public OAuth endpoints that don't require authentication
 */
const PUBLIC_OAUTH_PATHS = [
  '/oauth/token',
  '/oauth/validate',
  '/oauth/revoke',
  '/.well-known/openid-configuration',
];

/**
 * Authentication middleware for Fastify
 *
 * Token sources (checked in order):
 * 1. Authorization header: "Bearer <token>"
 * 2. URL query parameter: "?token=<token>"
 *
 * The query parameter support is specifically for web-based clients
 * like Claude Cloud that cannot set custom HTTP headers.
 */
export function authMiddleware(
  request: FastifyRequest,
  reply: FastifyReply,
  done: HookHandlerDoneFunction
): void {
  // Skip auth if disabled
  if (!authConfig?.enabled) {
    done();
    return;
  }

  // Skip auth for public OAuth endpoints
  const urlPath = request.url.split('?')[0]; // Remove query params
  if (PUBLIC_OAUTH_PATHS.includes(urlPath)) {
    done();
    return;
  }

  // Try to get token from Authorization header first
  let token = extractBearerToken(request.headers.authorization);

  // If no header token, try URL query parameter (?token=...)
  if (!token) {
    token = extractQueryToken(request.query);
  }

  if (!token) {
    log.warn({ path: request.url, ip: request.ip }, 'Missing authorization');
    reply.status(401).send({
      error: 'Unauthorized',
      message: 'Missing Authorization header or ?token= query parameter',
    });
    return;
  }

  const { valid, isAdmin } = validateToken(token);

  if (!valid) {
    log.warn({ path: request.url, ip: request.ip }, 'Invalid token');
    reply.status(401).send({
      error: 'Unauthorized',
      message: 'Invalid authentication token',
    });
    return;
  }

  // Attach auth info to request
  request.authToken = token;
  request.isAdmin = isAdmin;

  done();
}

/**
 * Admin-only middleware
 */
export function adminMiddleware(
  request: FastifyRequest,
  reply: FastifyReply,
  done: HookHandlerDoneFunction
): void {
  // Skip for public OAuth endpoints
  const urlPath = request.url.split('?')[0];
  if (PUBLIC_OAUTH_PATHS.includes(urlPath)) {
    done();
    return;
  }

  // First ensure regular auth passes
  if (authConfig?.enabled && !request.authToken) {
    reply.status(401).send({
      error: 'Unauthorized',
      message: 'Authentication required',
    });
    return;
  }

  // Check admin permission
  if (authConfig?.enabled && !request.isAdmin) {
    log.warn({ path: request.url, ip: request.ip }, 'Admin access denied');
    reply.status(403).send({
      error: 'Forbidden',
      message: 'Admin access required',
    });
    return;
  }

  done();
}

/**
 * Register auth middleware with Fastify
 */
export function registerAuthMiddleware(
  fastify: FastifyInstance,
  config: AuthConfig
): void {
  configureAuth(config);

  // Add auth hook to all routes
  fastify.addHook('preHandler', authMiddleware);
}

/**
 * Create an auth decorator for specific routes
 */
export function createAuthDecorator(fastify: FastifyInstance): void {
  fastify.decorate('authenticate', authMiddleware);
  fastify.decorate('authenticateAdmin', adminMiddleware);
}

declare module 'fastify' {
  interface FastifyInstance {
    authenticate: typeof authMiddleware;
    authenticateAdmin: typeof adminMiddleware;
  }
}
