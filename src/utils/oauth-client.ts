import { createChildLogger, type Logger } from './logger.js';
import type { OAuthConfig } from './config-loader.js';

/**
 * OAuth token response
 */
interface TokenResponse {
  access_token: string;
  token_type: string;
  expires_in?: number;
  refresh_token?: string;
  scope?: string;
}

/**
 * Cached token with expiry
 */
interface CachedToken {
  accessToken: string;
  tokenType: string;
  expiresAt: number;
  refreshToken?: string;
}

/**
 * OAuth client for managing access tokens
 */
export class OAuthClient {
  private readonly config: OAuthConfig;
  readonly serverId: string;
  private readonly log: Logger;
  private cachedToken: CachedToken | null = null;
  private refreshPromise: Promise<string> | null = null;

  constructor(serverId: string, config: OAuthConfig) {
    this.serverId = serverId;
    this.config = config;
    this.log = createChildLogger({ component: 'oauth-client', serverId });
  }

  /**
   * Get a valid access token, refreshing if necessary
   */
  async getAccessToken(): Promise<string> {
    // If we have a valid cached token, return it
    if (this.isTokenValid()) {
      return this.cachedToken!.accessToken;
    }

    // If a refresh is already in progress, wait for it
    if (this.refreshPromise) {
      return this.refreshPromise;
    }

    // Start a new token fetch
    this.refreshPromise = this.fetchToken();

    try {
      const token = await this.refreshPromise;
      return token;
    } finally {
      this.refreshPromise = null;
    }
  }

  /**
   * Get the authorization header value
   */
  async getAuthorizationHeader(): Promise<string> {
    const token = await this.getAccessToken();
    const tokenType = this.cachedToken?.tokenType || 'Bearer';
    return `${tokenType} ${token}`;
  }

  /**
   * Check if the cached token is still valid
   */
  private isTokenValid(): boolean {
    if (!this.cachedToken) {
      return false;
    }

    const now = Date.now();
    const refreshBuffer = (this.config.refreshBeforeExpiry || 60) * 1000;

    return this.cachedToken.expiresAt - refreshBuffer > now;
  }

  /**
   * Fetch a new token from the OAuth server
   */
  private async fetchToken(): Promise<string> {
    this.log.info({ tokenUrl: this.config.tokenUrl }, 'Fetching OAuth token');

    const body = this.buildTokenRequestBody();
    const headers: Record<string, string> = {
      'Content-Type': 'application/x-www-form-urlencoded',
    };

    // Some OAuth servers require Basic auth for client credentials
    if (this.config.grantType === 'client_credentials') {
      const resolvedClientId = this.resolveEnvVar(this.config.clientId);
      const resolvedClientSecret = this.resolveEnvVar(this.config.clientSecret);
      const credentials = Buffer.from(
        `${resolvedClientId}:${resolvedClientSecret}`
      ).toString('base64');
      headers['Authorization'] = `Basic ${credentials}`;
    }

    try {
      const response = await fetch(this.config.tokenUrl, {
        method: 'POST',
        headers,
        body: body.toString(),
      });

      if (!response.ok) {
        const errorText = await response.text();
        this.log.error(
          { status: response.status, error: errorText },
          'OAuth token request failed'
        );
        throw new Error(`OAuth token request failed: ${response.status} ${errorText}`);
      }

      const tokenResponse = (await response.json()) as TokenResponse;

      // Calculate expiry time
      const expiresIn = tokenResponse.expires_in || 3600; // Default to 1 hour
      const expiresAt = Date.now() + expiresIn * 1000;

      // Cache the token
      this.cachedToken = {
        accessToken: tokenResponse.access_token,
        tokenType: tokenResponse.token_type || 'Bearer',
        expiresAt,
        refreshToken: tokenResponse.refresh_token,
      };

      this.log.info(
        { expiresIn, tokenType: this.cachedToken.tokenType },
        'OAuth token obtained successfully'
      );

      return this.cachedToken.accessToken;
    } catch (error) {
      this.log.error({ error }, 'Failed to fetch OAuth token');
      throw error;
    }
  }

  /**
   * Build the token request body based on grant type
   */
  private buildTokenRequestBody(): URLSearchParams {
    const body = new URLSearchParams();

    body.append('grant_type', this.config.grantType);

    // For client_credentials, include client_id and client_secret in body as well
    // (some OAuth servers require this)
    if (this.config.grantType === 'client_credentials') {
      body.append('client_id', this.resolveEnvVar(this.config.clientId));
      body.append('client_secret', this.resolveEnvVar(this.config.clientSecret));
    }

    // For password grant
    if (this.config.grantType === 'password') {
      body.append('client_id', this.resolveEnvVar(this.config.clientId));
      body.append('client_secret', this.resolveEnvVar(this.config.clientSecret));
      body.append('username', this.resolveEnvVar(this.config.username!));
      body.append('password', this.resolveEnvVar(this.config.password!));
    }

    // For refresh token grant
    if (this.config.grantType === 'refresh_token' && this.cachedToken?.refreshToken) {
      body.append('client_id', this.resolveEnvVar(this.config.clientId));
      body.append('client_secret', this.resolveEnvVar(this.config.clientSecret));
      body.append('refresh_token', this.cachedToken.refreshToken);
    }

    // Add scopes if specified
    if (this.config.scopes && this.config.scopes.length > 0) {
      body.append('scope', this.config.scopes.join(' '));
    }

    // Add audience if specified (used by Auth0, etc.)
    if (this.config.audience) {
      body.append('audience', this.config.audience);
    }

    return body;
  }

  /**
   * Resolve environment variable references in config values
   * Supports ${VAR_NAME} syntax
   */
  private resolveEnvVar(value: string): string {
    return value.replace(/\$\{([^}]+)\}/g, (_match, envVar) => {
      const envValue = process.env[envVar];
      if (envValue === undefined) {
        this.log.warn(
          { envVar, serverId: this.serverId },
          `Environment variable "${envVar}" not found, using empty string`
        );
        return '';
      }
      return envValue;
    });
  }

  /**
   * Invalidate the cached token
   */
  invalidateToken(): void {
    this.cachedToken = null;
    this.log.info('OAuth token invalidated');
  }

  /**
   * Get token expiry information for monitoring
   */
  getTokenInfo(): { hasToken: boolean; expiresAt?: number; expiresIn?: number } {
    if (!this.cachedToken) {
      return { hasToken: false };
    }

    const now = Date.now();
    return {
      hasToken: true,
      expiresAt: this.cachedToken.expiresAt,
      expiresIn: Math.max(0, Math.floor((this.cachedToken.expiresAt - now) / 1000)),
    };
  }
}

/**
 * OAuth client registry for managing multiple OAuth clients
 */
class OAuthClientRegistry {
  private readonly clients: Map<string, OAuthClient> = new Map();

  /**
   * Get or create an OAuth client for a server
   */
  getClient(serverId: string, config: OAuthConfig): OAuthClient {
    let client = this.clients.get(serverId);
    if (!client) {
      client = new OAuthClient(serverId, config);
      this.clients.set(serverId, client);
    }
    return client;
  }

  /**
   * Remove an OAuth client
   */
  removeClient(serverId: string): void {
    this.clients.delete(serverId);
  }

  /**
   * Invalidate all tokens
   */
  invalidateAll(): void {
    for (const client of this.clients.values()) {
      client.invalidateToken();
    }
  }

  /**
   * Get all token info for monitoring
   */
  getAllTokenInfo(): Record<string, { hasToken: boolean; expiresAt?: number; expiresIn?: number }> {
    const info: Record<string, { hasToken: boolean; expiresAt?: number; expiresIn?: number }> = {};
    for (const [serverId, client] of this.clients) {
      info[serverId] = client.getTokenInfo();
    }
    return info;
  }
}

// Singleton registry
export const oauthRegistry = new OAuthClientRegistry();
