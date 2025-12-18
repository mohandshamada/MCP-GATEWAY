import EventSource from 'eventsource';
import { BaseAdapter, AdapterHealth } from './base.js';
import type { ServerConfig } from '../utils/config-loader.js';
import { OAuthClient, oauthRegistry } from '../utils/oauth-client.js';

/**
 * Adapter for MCP servers accessible via Server-Sent Events (SSE)
 */
export class SSEAdapter extends BaseAdapter {
  private eventSource: EventSource | null = null;
  private messageEndpoint: string | null = null;
  private sessionId: string | null = null;
  private isStarting: boolean = false;
  private oauthClient: OAuthClient | null = null;

  constructor(config: ServerConfig) {
    super(config);

    if (config.transport !== 'sse') {
      throw new Error(`SSEAdapter requires transport 'sse', got '${config.transport}'`);
    }

    if (!config.url) {
      throw new Error('SSEAdapter requires a url');
    }

    // Initialize OAuth client if configured
    if (config.oauth) {
      this.oauthClient = oauthRegistry.getClient(config.id, config.oauth);
      this.logger.info('OAuth authentication configured for SSE adapter');
    }
  }

  /**
   * Check if the SSE connection is open
   */
  isConnected(): boolean {
    return this.eventSource !== null && 
           this.eventSource.readyState === EventSource.OPEN;
  }

  /**
   * Start the SSE connection
   */
  async start(): Promise<void> {
    if (this.isStarting) {
      this.logger.warn('Adapter is already starting');
      return;
    }

    if (this.isConnected()) {
      this.logger.warn('Adapter is already connected');
      return;
    }

    this.isStarting = true;
    this.health = AdapterHealth.Starting;

    try {
      await this.connectSSE();
      await this.initialize();
      
      this.health = AdapterHealth.Healthy;
      this.startTime = new Date();
      this.retryCount = 0;
      this.emit('connected', this.config.id);
      
      this.logger.info('SSE adapter started successfully');
    } catch (error) {
      this.health = AdapterHealth.Unhealthy;
      this.logger.error({ error }, 'Failed to start SSE adapter');
      throw error;
    } finally {
      this.isStarting = false;
    }
  }

  /**
   * Build headers for SSE connection
   */
  private async buildHeaders(): Promise<Record<string, string>> {
    const headers: Record<string, string> = {};

    // Add OAuth authorization header if configured
    if (this.oauthClient) {
      try {
        headers['Authorization'] = await this.oauthClient.getAuthorizationHeader();
        this.logger.debug('OAuth authorization header added');
      } catch (error) {
        this.logger.error({ error }, 'Failed to get OAuth token');
        throw error;
      }
    }

    // Add any custom headers from environment
    if (this.config.env) {
      for (const [key, value] of Object.entries(this.config.env)) {
        if (key.startsWith('HEADER_')) {
          const headerName = key.substring(7).toLowerCase().replace(/_/g, '-');
          headers[headerName] = this.resolveEnvVar(value);
        }
      }
    }

    return headers;
  }

  /**
   * Resolve environment variable references in config values
   */
  private resolveEnvVar(value: string): string {
    return value.replace(/\$\{([^}]+)\}/g, (_match, envVar) => {
      const envValue = process.env[envVar];
      if (envValue === undefined) {
        this.logger.warn(
          { envVar, serverId: this.config.id },
          `Environment variable "${envVar}" not found, using empty string`
        );
        return '';
      }
      return envValue;
    });
  }

  /**
   * Establish SSE connection
   */
  private async connectSSE(): Promise<void> {
    const sseUrl = this.config.url!;

    this.logger.info({ url: sseUrl }, 'Connecting to SSE endpoint');

    // Build headers (including OAuth if configured)
    const headers = await this.buildHeaders();

    return new Promise((resolve, reject) => {
      this.eventSource = new EventSource(sseUrl, {
        headers: Object.keys(headers).length > 0 ? headers : undefined,
      });

      const timeout = setTimeout(() => {
        reject(new Error('SSE connection timeout'));
        this.eventSource?.close();
      }, 30000);

      this.eventSource.onopen = (): void => {
        this.logger.info('SSE connection opened');
        clearTimeout(timeout);
      };

      // Handle endpoint event (MCP SSE protocol)
      this.eventSource.addEventListener('endpoint', (event) => {
        try {
          const data = JSON.parse(event.data);
          this.messageEndpoint = data.endpoint;
          this.sessionId = data.sessionId;
          this.logger.info(
            { endpoint: this.messageEndpoint, sessionId: this.sessionId },
            'Received message endpoint'
          );
          resolve();
        } catch (error) {
          this.logger.error({ error, data: event.data }, 'Failed to parse endpoint event');
          reject(error);
        }
      });

      // Handle message events
      this.eventSource.addEventListener('message', (event) => {
        this.handleMessage(event.data);
      });

      this.eventSource.onerror = (error: Event): void => {
        this.logger.error({ error }, 'SSE connection error');
        
        if (this.eventSource?.readyState === EventSource.CLOSED) {
          this.cancelPendingRequests('SSE connection closed');
          
          if (this.health === AdapterHealth.Healthy) {
            // Unexpected disconnect, try to recover
            this.handleCrash().catch((err) => {
              this.logger.error({ error: err }, 'Failed to handle crash');
            });
          }
        }
        
        // Only reject if we haven't connected yet
        if (!this.messageEndpoint) {
          clearTimeout(timeout);
          reject(new Error('SSE connection failed'));
        }
      };
    });
  }

  /**
   * Send raw message via HTTP POST
   */
  protected async sendRaw(message: string): Promise<void> {
    if (!this.messageEndpoint) {
      throw new Error('No message endpoint available');
    }

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };

    if (this.sessionId) {
      headers['X-Session-ID'] = this.sessionId;
    }

    // Add OAuth authorization header if configured
    if (this.oauthClient) {
      try {
        headers['Authorization'] = await this.oauthClient.getAuthorizationHeader();
      } catch (error) {
        this.logger.error({ error }, 'Failed to get OAuth token for request');
        throw error;
      }
    }

    // Add any custom headers from environment
    if (this.config.env) {
      for (const [key, value] of Object.entries(this.config.env)) {
        if (key.startsWith('HEADER_')) {
          const headerName = key.substring(7).toLowerCase().replace(/_/g, '-');
          headers[headerName] = this.resolveEnvVar(value);
        }
      }
    }

    const response = await fetch(this.messageEndpoint, {
      method: 'POST',
      headers,
      body: message,
    });

    if (!response.ok) {
      const errorText = await response.text();

      // If we get a 401, invalidate the token and retry once
      if (response.status === 401 && this.oauthClient) {
        this.logger.warn('Received 401, invalidating OAuth token and retrying');
        this.oauthClient.invalidateToken();

        // Get new token and retry
        headers['Authorization'] = await this.oauthClient.getAuthorizationHeader();
        const retryResponse = await fetch(this.messageEndpoint, {
          method: 'POST',
          headers,
          body: message,
        });

        if (!retryResponse.ok) {
          const retryErrorText = await retryResponse.text();
          throw new Error(`HTTP ${retryResponse.status}: ${retryErrorText}`);
        }
        return;
      }

      throw new Error(`HTTP ${response.status}: ${errorText}`);
    }
  }

  /**
   * Stop the SSE connection
   */
  async stop(): Promise<void> {
    if (!this.eventSource) {
      return;
    }

    this.logger.info('Stopping SSE adapter');
    this.health = AdapterHealth.Stopped;

    // Cancel pending requests
    this.cancelPendingRequests('Adapter stopped');

    // Close the EventSource
    this.eventSource.close();
    this.eventSource = null;
    this.messageEndpoint = null;
    this.sessionId = null;
  }

  /**
   * Restart the adapter
   */
  async restart(): Promise<void> {
    await this.stop();
    await this.start();
  }
}
