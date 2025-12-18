import crypto from 'crypto';
import { createChildLogger, type Logger } from '../utils/logger.js';

/**
 * OAuth client configuration
 */
export interface OAuthClientConfig {
  clientId: string;
  clientSecret: string;
  name: string;
  scopes: string[];
  grantTypes: ('client_credentials' | 'password' | 'refresh_token')[];
}

/**
 * Stored token information
 */
interface StoredToken {
  accessToken: string;
  tokenType: string;
  clientId: string;
  scopes: string[];
  expiresAt: number;
  refreshToken?: string;
  username?: string;
}

/**
 * Token response
 */
export interface TokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  scope?: string;
  refresh_token?: string;
}

/**
 * OAuth server configuration
 */
export interface OAuthServerConfig {
  enabled: boolean;
  issuer?: string;
  tokenExpiresIn?: number; // seconds, default 3600
  refreshTokenExpiresIn?: number; // seconds, default 86400
  clients?: OAuthClientConfig[];
}

/**
 * Built-in OAuth2 Authorization Server
 *
 * Supports:
 * - client_credentials grant
 * - password grant
 * - refresh_token grant
 */
export class OAuthServer {
  private readonly config: OAuthServerConfig;
  private readonly log: Logger;
  private readonly clients: Map<string, OAuthClientConfig> = new Map();
  private readonly tokens: Map<string, StoredToken> = new Map();
  private readonly refreshTokens: Map<string, { clientId: string; username?: string; expiresAt: number }> = new Map();
  private cleanupInterval: NodeJS.Timeout | null = null;

  constructor(config: OAuthServerConfig) {
    this.config = {
      tokenExpiresIn: 3600,
      refreshTokenExpiresIn: 86400,
      ...config
    };
    this.log = createChildLogger({ component: 'oauth-server' });

    // Register configured clients
    if (config.clients) {
      for (const client of config.clients) {
        this.registerClient(client);
      }
    }

    // Start token cleanup
    this.startCleanup();

    this.log.info({ clientCount: this.clients.size }, 'OAuth server initialized');
  }

  /**
   * Register an OAuth client
   */
  registerClient(client: OAuthClientConfig): void {
    this.clients.set(client.clientId, client);
    this.log.info({ clientId: client.clientId, name: client.name }, 'OAuth client registered');
  }

  /**
   * Remove an OAuth client
   */
  removeClient(clientId: string): boolean {
    const removed = this.clients.delete(clientId);
    if (removed) {
      // Revoke all tokens for this client
      for (const [token, stored] of this.tokens) {
        if (stored.clientId === clientId) {
          this.tokens.delete(token);
        }
      }
      this.log.info({ clientId }, 'OAuth client removed');
    }
    return removed;
  }

  /**
   * Get all registered clients (without secrets)
   */
  getClients(): Array<{ clientId: string; name: string; scopes: string[]; grantTypes: string[] }> {
    return Array.from(this.clients.values()).map(c => ({
      clientId: c.clientId,
      name: c.name,
      scopes: c.scopes,
      grantTypes: c.grantTypes
    }));
  }

  /**
   * Validate client credentials
   */
  private validateClient(clientId: string, clientSecret: string): OAuthClientConfig | null {
    const client = this.clients.get(clientId);
    if (!client) {
      this.log.warn({ clientId }, 'Unknown client');
      return null;
    }

    if (client.clientSecret !== clientSecret) {
      this.log.warn({ clientId }, 'Invalid client secret');
      return null;
    }

    return client;
  }

  /**
   * Generate a secure random token
   */
  private generateToken(): string {
    return crypto.randomBytes(32).toString('hex');
  }

  /**
   * Handle token request
   */
  async handleTokenRequest(params: {
    grant_type: string;
    client_id?: string;
    client_secret?: string;
    scope?: string;
    username?: string;
    password?: string;
    refresh_token?: string;
  }, basicAuth?: { clientId: string; clientSecret: string }): Promise<TokenResponse | { error: string; error_description: string }> {

    // Get client credentials from Basic Auth or body
    const clientId = basicAuth?.clientId || params.client_id;
    const clientSecret = basicAuth?.clientSecret || params.client_secret;

    if (!clientId || !clientSecret) {
      return {
        error: 'invalid_request',
        error_description: 'Missing client credentials'
      };
    }

    const client = this.validateClient(clientId, clientSecret);
    if (!client) {
      return {
        error: 'invalid_client',
        error_description: 'Invalid client credentials'
      };
    }

    const grantType = params.grant_type as 'client_credentials' | 'password' | 'refresh_token';

    // Validate grant type is allowed for this client
    if (!client.grantTypes.includes(grantType)) {
      return {
        error: 'unauthorized_client',
        error_description: `Grant type '${grantType}' not allowed for this client`
      };
    }

    switch (grantType) {
      case 'client_credentials':
        return this.handleClientCredentials(client, params.scope);

      case 'password':
        if (!params.username || !params.password) {
          return {
            error: 'invalid_request',
            error_description: 'Username and password required'
          };
        }
        return this.handlePasswordGrant(client, params.username, params.password, params.scope);

      case 'refresh_token':
        if (!params.refresh_token) {
          return {
            error: 'invalid_request',
            error_description: 'Refresh token required'
          };
        }
        return this.handleRefreshToken(client, params.refresh_token, params.scope);

      default:
        return {
          error: 'unsupported_grant_type',
          error_description: `Grant type '${grantType}' not supported`
        };
    }
  }

  /**
   * Handle client_credentials grant
   */
  private handleClientCredentials(client: OAuthClientConfig, requestedScope?: string): TokenResponse {
    const scopes = this.resolveScopes(client.scopes, requestedScope);
    const accessToken = this.generateToken();
    const expiresIn = this.config.tokenExpiresIn!;

    this.tokens.set(accessToken, {
      accessToken,
      tokenType: 'Bearer',
      clientId: client.clientId,
      scopes,
      expiresAt: Date.now() + (expiresIn * 1000)
    });

    this.log.info({ clientId: client.clientId, scopes }, 'Token issued (client_credentials)');

    return {
      access_token: accessToken,
      token_type: 'Bearer',
      expires_in: expiresIn,
      scope: scopes.join(' ')
    };
  }

  /**
   * Handle password grant
   * Note: In production, you'd validate against a user store
   */
  private handlePasswordGrant(
    client: OAuthClientConfig,
    username: string,
    _password: string, // In production, validate against user database
    requestedScope?: string
  ): TokenResponse | { error: string; error_description: string } {
    // Simple validation - in production, validate against user database
    // For now, accept any username/password combination
    // You can customize this by extending the class

    const scopes = this.resolveScopes(client.scopes, requestedScope);
    const accessToken = this.generateToken();
    const refreshToken = this.generateToken();
    const expiresIn = this.config.tokenExpiresIn!;

    this.tokens.set(accessToken, {
      accessToken,
      tokenType: 'Bearer',
      clientId: client.clientId,
      scopes,
      expiresAt: Date.now() + (expiresIn * 1000),
      refreshToken,
      username
    });

    this.refreshTokens.set(refreshToken, {
      clientId: client.clientId,
      username,
      expiresAt: Date.now() + (this.config.refreshTokenExpiresIn! * 1000)
    });

    this.log.info({ clientId: client.clientId, username, scopes }, 'Token issued (password)');

    return {
      access_token: accessToken,
      token_type: 'Bearer',
      expires_in: expiresIn,
      refresh_token: refreshToken,
      scope: scopes.join(' ')
    };
  }

  /**
   * Handle refresh_token grant
   */
  private handleRefreshToken(
    client: OAuthClientConfig,
    refreshToken: string,
    requestedScope?: string
  ): TokenResponse | { error: string; error_description: string } {
    const stored = this.refreshTokens.get(refreshToken);

    if (!stored) {
      return {
        error: 'invalid_grant',
        error_description: 'Invalid refresh token'
      };
    }

    if (stored.clientId !== client.clientId) {
      return {
        error: 'invalid_grant',
        error_description: 'Refresh token was issued to a different client'
      };
    }

    if (stored.expiresAt < Date.now()) {
      this.refreshTokens.delete(refreshToken);
      return {
        error: 'invalid_grant',
        error_description: 'Refresh token has expired'
      };
    }

    // Issue new tokens
    const scopes = this.resolveScopes(client.scopes, requestedScope);
    const accessToken = this.generateToken();
    const newRefreshToken = this.generateToken();
    const expiresIn = this.config.tokenExpiresIn!;

    // Remove old refresh token
    this.refreshTokens.delete(refreshToken);

    // Store new tokens
    this.tokens.set(accessToken, {
      accessToken,
      tokenType: 'Bearer',
      clientId: client.clientId,
      scopes,
      expiresAt: Date.now() + (expiresIn * 1000),
      refreshToken: newRefreshToken,
      username: stored.username
    });

    this.refreshTokens.set(newRefreshToken, {
      clientId: client.clientId,
      username: stored.username,
      expiresAt: Date.now() + (this.config.refreshTokenExpiresIn! * 1000)
    });

    this.log.info({ clientId: client.clientId }, 'Token refreshed');

    return {
      access_token: accessToken,
      token_type: 'Bearer',
      expires_in: expiresIn,
      refresh_token: newRefreshToken,
      scope: scopes.join(' ')
    };
  }

  /**
   * Resolve requested scopes against allowed scopes
   */
  private resolveScopes(allowedScopes: string[], requestedScope?: string): string[] {
    if (!requestedScope) {
      return allowedScopes;
    }

    const requested = requestedScope.split(' ').filter(s => s.length > 0);
    return requested.filter(s => allowedScopes.includes(s));
  }

  /**
   * Validate an access token
   */
  validateToken(accessToken: string): StoredToken | null {
    const stored = this.tokens.get(accessToken);

    if (!stored) {
      return null;
    }

    if (stored.expiresAt < Date.now()) {
      this.tokens.delete(accessToken);
      return null;
    }

    return stored;
  }

  /**
   * Revoke a token
   */
  revokeToken(accessToken: string): boolean {
    const stored = this.tokens.get(accessToken);
    if (stored) {
      this.tokens.delete(accessToken);
      if (stored.refreshToken) {
        this.refreshTokens.delete(stored.refreshToken);
      }
      this.log.info({ clientId: stored.clientId }, 'Token revoked');
      return true;
    }
    return false;
  }

  /**
   * Get OpenID Connect discovery document
   */
  getDiscoveryDocument(baseUrl: string): Record<string, unknown> {
    return {
      issuer: this.config.issuer || baseUrl,
      authorization_endpoint: `${baseUrl}/oauth/authorize`,
      token_endpoint: `${baseUrl}/oauth/token`,
      token_endpoint_auth_methods_supported: ['client_secret_basic', 'client_secret_post'],
      grant_types_supported: ['client_credentials', 'password', 'refresh_token'],
      revocation_endpoint: `${baseUrl}/oauth/revoke`,
      scopes_supported: this.getAllScopes(),
      response_types_supported: ['token']
    };
  }

  /**
   * Get all unique scopes from all clients
   */
  private getAllScopes(): string[] {
    const scopes = new Set<string>();
    for (const client of this.clients.values()) {
      for (const scope of client.scopes) {
        scopes.add(scope);
      }
    }
    return Array.from(scopes);
  }

  /**
   * Start periodic cleanup of expired tokens
   */
  private startCleanup(): void {
    this.cleanupInterval = setInterval(() => {
      const now = Date.now();
      let cleaned = 0;

      for (const [token, stored] of this.tokens) {
        if (stored.expiresAt < now) {
          this.tokens.delete(token);
          cleaned++;
        }
      }

      for (const [token, stored] of this.refreshTokens) {
        if (stored.expiresAt < now) {
          this.refreshTokens.delete(token);
          cleaned++;
        }
      }

      if (cleaned > 0) {
        this.log.debug({ cleaned }, 'Cleaned up expired tokens');
      }
    }, 60000); // Run every minute
  }

  /**
   * Stop the OAuth server
   */
  stop(): void {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
      this.cleanupInterval = null;
    }
    this.log.info('OAuth server stopped');
  }

  /**
   * Get server statistics
   */
  getStats(): { clients: number; activeTokens: number; refreshTokens: number } {
    return {
      clients: this.clients.size,
      activeTokens: this.tokens.size,
      refreshTokens: this.refreshTokens.size
    };
  }
}

// Singleton instance
let oauthServerInstance: OAuthServer | null = null;

/**
 * Initialize the OAuth server
 */
export function initOAuthServer(config: OAuthServerConfig): OAuthServer {
  if (oauthServerInstance) {
    oauthServerInstance.stop();
  }
  oauthServerInstance = new OAuthServer(config);
  return oauthServerInstance;
}

/**
 * Get the OAuth server instance
 */
export function getOAuthServer(): OAuthServer | null {
  return oauthServerInstance;
}
