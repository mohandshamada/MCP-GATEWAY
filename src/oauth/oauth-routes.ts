import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { getOAuthServer } from './oauth-server.js';
import { logger } from '../utils/logger.js';

/**
 * Extract Basic Auth credentials from Authorization header
 */
function extractBasicAuth(authHeader?: string): { clientId: string; clientSecret: string } | null {
  if (!authHeader?.startsWith('Basic ')) {
    return null;
  }

  try {
    const decoded = Buffer.from(authHeader.slice(6), 'base64').toString();
    const [clientId, clientSecret] = decoded.split(':');
    if (clientId && clientSecret) {
      return { clientId, clientSecret };
    }
  } catch {
    // Invalid base64
  }
  return null;
}

/**
 * Register OAuth routes
 */
export function registerOAuthRoutes(app: FastifyInstance): void {
  const log = logger.child({ component: 'oauth-routes' });

  /**
   * Token endpoint
   * POST /oauth/token
   */
  app.post('/oauth/token', async (request: FastifyRequest, reply: FastifyReply) => {
    const oauthServer = getOAuthServer();

    if (!oauthServer) {
      return reply.status(503).send({
        error: 'server_error',
        error_description: 'OAuth server not enabled'
      });
    }

    // Parse request body (support both JSON and form-urlencoded)
    let params: Record<string, string> = {};

    const contentType = request.headers['content-type'] || '';

    if (contentType.includes('application/json')) {
      params = request.body as Record<string, string>;
    } else if (contentType.includes('application/x-www-form-urlencoded')) {
      params = request.body as Record<string, string>;
    } else {
      // Try to parse as form data
      params = request.body as Record<string, string>;
    }

    // Extract Basic Auth if present
    const basicAuth = extractBasicAuth(request.headers.authorization);

    log.info({ grant_type: params.grant_type, client_id: params.client_id || basicAuth?.clientId }, 'Token request');

    const tokenParams = {
      grant_type: params.grant_type || '',
      client_id: params.client_id,
      client_secret: params.client_secret,
      scope: params.scope,
      username: params.username,
      password: params.password,
      refresh_token: params.refresh_token,
    };

    const result = await oauthServer.handleTokenRequest(tokenParams, basicAuth || undefined);

    if ('error' in result) {
      return reply.status(400).send(result);
    }

    // Set cache control headers
    reply.header('Cache-Control', 'no-store');
    reply.header('Pragma', 'no-cache');

    return reply.send(result);
  });

  /**
   * Token revocation endpoint
   * POST /oauth/revoke
   */
  app.post('/oauth/revoke', async (request: FastifyRequest, reply: FastifyReply) => {
    const oauthServer = getOAuthServer();

    if (!oauthServer) {
      return reply.status(503).send({
        error: 'server_error',
        error_description: 'OAuth server not enabled'
      });
    }

    const body = request.body as { token?: string };

    if (!body.token) {
      return reply.status(400).send({
        error: 'invalid_request',
        error_description: 'Token is required'
      });
    }

    oauthServer.revokeToken(body.token);

    // Always return 200 OK for revocation (even if token didn't exist)
    return reply.status(200).send({});
  });

  /**
   * OpenID Connect Discovery endpoint
   * GET /.well-known/openid-configuration
   */
  app.get('/.well-known/openid-configuration', async (request: FastifyRequest, reply: FastifyReply) => {
    const oauthServer = getOAuthServer();

    if (!oauthServer) {
      return reply.status(503).send({
        error: 'server_error',
        error_description: 'OAuth server not enabled'
      });
    }

    // Build base URL from request
    const protocol = request.headers['x-forwarded-proto'] || 'http';
    const host = request.headers['x-forwarded-host'] || request.headers.host || 'localhost';
    const baseUrl = `${protocol}://${host}`;

    return reply.send(oauthServer.getDiscoveryDocument(baseUrl));
  });

  /**
   * OAuth server info endpoint (admin)
   * GET /oauth/info
   */
  app.get('/oauth/info', async (_request: FastifyRequest, reply: FastifyReply) => {
    const oauthServer = getOAuthServer();

    if (!oauthServer) {
      return reply.send({
        enabled: false
      });
    }

    return reply.send({
      enabled: true,
      stats: oauthServer.getStats(),
      clients: oauthServer.getClients()
    });
  });

  /**
   * Register OAuth client (admin)
   * POST /oauth/clients
   */
  app.post('/oauth/clients', async (request: FastifyRequest, reply: FastifyReply) => {
    const oauthServer = getOAuthServer();

    if (!oauthServer) {
      return reply.status(503).send({
        error: 'server_error',
        error_description: 'OAuth server not enabled'
      });
    }

    const body = request.body as {
      clientId?: string;
      clientSecret?: string;
      name?: string;
      scopes?: string[];
      grantTypes?: string[];
    };

    if (!body.clientId || !body.clientSecret || !body.name) {
      return reply.status(400).send({
        error: 'invalid_request',
        error_description: 'clientId, clientSecret, and name are required'
      });
    }

    const validGrantTypes = ['client_credentials', 'password', 'refresh_token'];
    const grantTypes = (body.grantTypes || ['client_credentials']).filter(
      g => validGrantTypes.includes(g)
    ) as ('client_credentials' | 'password' | 'refresh_token')[];

    oauthServer.registerClient({
      clientId: body.clientId,
      clientSecret: body.clientSecret,
      name: body.name,
      scopes: body.scopes || ['mcp:read', 'mcp:write'],
      grantTypes
    });

    return reply.status(201).send({
      success: true,
      client: {
        clientId: body.clientId,
        name: body.name,
        scopes: body.scopes || ['mcp:read', 'mcp:write'],
        grantTypes
      }
    });
  });

  /**
   * Remove OAuth client (admin)
   * DELETE /oauth/clients/:clientId
   */
  app.delete('/oauth/clients/:clientId', async (request: FastifyRequest<{ Params: { clientId: string } }>, reply: FastifyReply) => {
    const oauthServer = getOAuthServer();

    if (!oauthServer) {
      return reply.status(503).send({
        error: 'server_error',
        error_description: 'OAuth server not enabled'
      });
    }

    const { clientId } = request.params;
    const removed = oauthServer.removeClient(clientId);

    if (!removed) {
      return reply.status(404).send({
        error: 'not_found',
        error_description: 'Client not found'
      });
    }

    return reply.send({
      success: true,
      message: `Client '${clientId}' removed`
    });
  });

  /**
   * Validate token endpoint (for debugging)
   * POST /oauth/validate
   */
  app.post('/oauth/validate', async (request: FastifyRequest, reply: FastifyReply) => {
    const oauthServer = getOAuthServer();

    if (!oauthServer) {
      return reply.status(503).send({
        error: 'server_error',
        error_description: 'OAuth server not enabled'
      });
    }

    const body = request.body as { token?: string };

    if (!body.token) {
      return reply.status(400).send({
        error: 'invalid_request',
        error_description: 'Token is required'
      });
    }

    const tokenInfo = oauthServer.validateToken(body.token);

    if (!tokenInfo) {
      return reply.status(401).send({
        active: false
      });
    }

    return reply.send({
      active: true,
      client_id: tokenInfo.clientId,
      scope: tokenInfo.scopes.join(' '),
      expires_at: Math.floor(tokenInfo.expiresAt / 1000),
      token_type: tokenInfo.tokenType
    });
  });

  log.info('OAuth routes registered');
}
