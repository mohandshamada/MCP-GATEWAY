import { readFileSync, existsSync, watchFile, copyFileSync, writeFileSync } from 'fs';
import { z } from 'zod';
import { logger } from './logger.js';

/**
 * Schema for OAuth configuration
 */
export const OAuthConfigSchema = z.object({
  clientId: z.string().min(1),
  clientSecret: z.string().min(1),
  tokenUrl: z.string().url(),
  scopes: z.array(z.string()).optional(),
  audience: z.string().optional(),
  grantType: z.enum(['client_credentials', 'password', 'refresh_token']).default('client_credentials'),
  // For password grant type
  username: z.string().optional(),
  password: z.string().optional(),
  // Token refresh settings
  refreshBeforeExpiry: z.number().min(0).max(300).default(60), // Refresh 60 seconds before expiry
});

export type OAuthConfig = z.infer<typeof OAuthConfigSchema>;

/**
 * Schema for individual server configuration
 */
export const ServerConfigSchema = z.object({
  id: z
    .string()
    .min(1)
    .max(64)
    .regex(/^[a-zA-Z][a-zA-Z0-9_-]*$/, {
      message: 'Server ID must start with a letter and contain only alphanumeric characters, underscores, or hyphens',
    }),
  transport: z.enum(['stdio', 'sse']),
  command: z.string().optional(),
  args: z.array(z.string()).optional(),
  url: z.string().url().optional(),
  env: z.record(z.string()).optional(),
  oauth: OAuthConfigSchema.optional(),
  enabled: z.boolean().default(true),
  lazyLoad: z.boolean().default(false),
  timeout: z.number().min(1000).max(300000).default(60000),
  maxRetries: z.number().min(0).max(10).default(3),
}).refine(
  (data) => {
    if (data.transport === 'stdio') {
      return !!data.command;
    }
    if (data.transport === 'sse') {
      return !!data.url;
    }
    return false;
  },
  {
    message: 'Stdio transport requires "command", SSE transport requires "url"',
  }
).refine(
  (data) => {
    // If OAuth is configured with password grant, username and password are required
    if (data.oauth?.grantType === 'password') {
      return !!data.oauth.username && !!data.oauth.password;
    }
    return true;
  },
  {
    message: 'OAuth password grant type requires "username" and "password"',
  }
);

export type ServerConfig = z.infer<typeof ServerConfigSchema>;

/**
 * Schema for gateway-level OAuth configuration (for Claude app integration)
 */
export const GatewayOAuthSchema = z.object({
  enabled: z.boolean().default(false),
  clientId: z.string().min(1).optional(),
  clientSecret: z.string().min(1).optional(),
  issuer: z.string().url().optional(),
  authorizationUrl: z.string().url().optional(),
  tokenUrl: z.string().url().optional(),
  scopes: z.array(z.string()).default(['mcp:read', 'mcp:write']),
}).refine(
  (data) => {
    if (data.enabled) {
      return !!data.clientId && !!data.clientSecret;
    }
    return true;
  },
  {
    message: 'OAuth requires clientId and clientSecret when enabled',
  }
);

export type GatewayOAuth = z.infer<typeof GatewayOAuthSchema>;

/**
 * Schema for OAuth client configuration (built-in server)
 */
export const OAuthClientSchema = z.object({
  clientId: z.string().min(1),
  clientSecret: z.string().min(1),
  name: z.string().min(1),
  scopes: z.array(z.string()).default(['mcp:read', 'mcp:write']),
  grantTypes: z.array(z.enum(['client_credentials', 'password', 'refresh_token'])).default(['client_credentials']),
});

export type OAuthClientDef = z.infer<typeof OAuthClientSchema>;

/**
 * Schema for built-in OAuth server configuration
 */
export const OAuthServerSchema = z.object({
  enabled: z.boolean().default(false),
  issuer: z.string().optional(),
  tokenExpiresIn: z.number().min(60).max(86400).default(3600), // 1 hour default
  refreshTokenExpiresIn: z.number().min(3600).max(2592000).default(86400), // 24 hours default
  clients: z.array(OAuthClientSchema).default([]),
});

export type OAuthServerDef = z.infer<typeof OAuthServerSchema>;

/**
 * Schema for domain/proxy configuration
 */
export const DomainConfigSchema = z.object({
  domain: z.string().nullable().optional(),
  publicUrl: z.string().url().nullable().optional(),
  ssl: z.object({
    enabled: z.boolean().default(false),
    email: z.string().email().nullable().optional(),
  }).default({}),
  proxy: z.object({
    enabled: z.boolean().default(false),
    type: z.enum(['caddy', 'nginx', 'custom']).default('caddy'),
  }).default({}),
  // CORS allowed origins - empty array allows all origins (development mode)
  // In production, specify allowed origins like ["https://example.com"]
  allowedOrigins: z.array(z.string().url()).default([]),
});

export type DomainConfig = z.infer<typeof DomainConfigSchema>;

/**
 * Schema for gateway configuration
 */
export const GatewayConfigSchema = z.object({
  gateway: z.object({
    host: z.string().default('127.0.0.1'),
    port: z.number().min(1).max(65535).default(3000),
    name: z.string().default('MCP Gateway'),
    version: z.string().default('1.0.0'),
  }),
  domain: DomainConfigSchema.default({}),
  auth: z.object({
    enabled: z.boolean().default(true),
    tokens: z.array(z.string()).default([]),
    oauth: GatewayOAuthSchema.default({}),
  }),
  oauthServer: OAuthServerSchema.default({}),
  servers: z.array(ServerConfigSchema),
  settings: z.object({
    requestTimeout: z.number().min(1000).max(300000).default(60000),
    enableHealthChecks: z.boolean().default(true),
    healthCheckInterval: z.number().min(5000).max(300000).default(30000),
    enableHotReload: z.boolean().default(true),
    sessionTimeout: z.number().min(60000).max(86400000).default(3600000), // 1 hour default
    enableRateLimiting: z.boolean().default(true),
    rateLimit: z.object({
      windowMs: z.number().min(1000).max(3600000).default(60000), // 1 minute window
      maxRequests: z.number().min(1).max(10000).default(100), // 100 requests per window
    }).default({}),
  }).default({}),
});

export type GatewayConfig = z.infer<typeof GatewayConfigSchema>;

/**
 * Load and validate configuration from a JSON file
 */
export function loadConfig(configPath: string): GatewayConfig {
  if (!existsSync(configPath)) {
    throw new Error(`Configuration file not found: ${configPath}`);
  }

  try {
    const rawConfig = readFileSync(configPath, 'utf-8');
    const parsedConfig = JSON.parse(rawConfig);
    
    const result = GatewayConfigSchema.safeParse(parsedConfig);
    
    if (!result.success) {
      const errors = result.error.errors.map(
        (e) => `  - ${e.path.join('.')}: ${e.message}`
      ).join('\n');
      throw new Error(`Configuration validation failed:\n${errors}`);
    }

    logger.info({ configPath }, 'Configuration loaded successfully');
    return result.data;
  } catch (error) {
    if (error instanceof SyntaxError) {
      throw new Error(`Invalid JSON in configuration file: ${error.message}`);
    }
    throw error;
  }
}

/**
 * Save configuration to disk with backup and validation
 * @param configPath - Path to gateway.json
 * @param config - Configuration object to save
 * @throws Error if validation or write fails
 */
export function saveConfig(configPath: string, config: GatewayConfig): void {
  try {
    // Validate configuration before saving
    const result = GatewayConfigSchema.safeParse(config);
    if (!result.success) {
      const validationErrors = result.error.errors
        .map(e => `${e.path.join('.')}: ${e.message}`)
        .join('; ');
      throw new Error(`Configuration validation failed: ${validationErrors}`);
    }

    // Create timestamped backup of current config
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const backupPath = configPath.replace('.json', `.backup.${timestamp}.json`);

    if (existsSync(configPath)) {
      try {
        copyFileSync(configPath, backupPath);
        logger.info({ backupPath }, 'Configuration backup created before save');
      } catch (backupError) {
        logger.warn({ backupError, backupPath }, 'Failed to create backup, continuing without backup');
      }
    }

    // Write configuration with proper formatting (for readability in git/diffs)
    const jsonContent = JSON.stringify(result.data, null, 2);
    writeFileSync(configPath, jsonContent, 'utf-8');

    logger.info(
      {
        configPath,
        serverCount: result.data.servers.length,
        backupPath: existsSync(backupPath) ? backupPath : 'N/A',
      },
      'Configuration successfully saved to disk'
    );
  } catch (error) {
    logger.error(
      {
        error: error instanceof Error ? error.message : String(error),
        configPath,
        stack: error instanceof Error ? error.stack : undefined,
      },
      'Failed to save configuration to disk'
    );
    throw new Error(
      `Failed to save configuration: ${error instanceof Error ? error.message : String(error)}`
    );
  }
}

/**
 * Load authentication tokens from environment or config
 */
export function loadAuthTokens(config: GatewayConfig): string[] {
  const tokens: string[] = [];

  // Load from config file
  if (config.auth.tokens) {
    tokens.push(...config.auth.tokens);
  }

  // Load from environment variable (comma-separated)
  const envTokens = process.env.MCP_GATEWAY_TOKENS;
  if (envTokens) {
    tokens.push(...envTokens.split(',').map((t) => t.trim()).filter(Boolean));
  }

  // Load individual token from environment
  const singleToken = process.env.MCP_GATEWAY_TOKEN;
  if (singleToken) {
    tokens.push(singleToken);
  }

  return [...new Set(tokens)]; // Deduplicate
}

/**
 * Watch configuration file for changes
 */
export function watchConfig(
  configPath: string,
  callback: (config: GatewayConfig) => void
): void {
  watchFile(configPath, { interval: 1000 }, () => {
    logger.info({ configPath }, 'Configuration file changed, reloading...');
    try {
      const newConfig = loadConfig(configPath);
      callback(newConfig);
    } catch (error) {
      logger.error({ error, configPath }, 'Failed to reload configuration');
    }
  });
}

/**
 * Validate a single server configuration
 */
export function validateServerConfig(config: unknown): ServerConfig {
  const result = ServerConfigSchema.safeParse(config);
  if (!result.success) {
    const errors = result.error.errors.map(
      (e) => `${e.path.join('.')}: ${e.message}`
    ).join(', ');
    throw new Error(`Invalid server configuration: ${errors}`);
  }
  return result.data;
}

// =====================================================
// Issue #7: Environment Variable Validation
// =====================================================

/**
 * Validate environment variables for security and correctness
 * @param env - Record of environment variables
 * @returns Validated environment variables
 * @throws Error if validation fails
 */
export function validateEnvironmentVariables(env: Record<string, string>): Record<string, string> {
  const validated: Record<string, string> = {};

  for (const [key, value] of Object.entries(env)) {
    // Validate key format (must start with letter/underscore, contain only alphanumeric/underscore)
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      throw new Error(`Invalid environment variable name: ${key}. Must start with a letter or underscore and contain only alphanumeric characters and underscores.`);
    }
    // Validate value type and length
    if (typeof value !== 'string') {
      throw new Error(`Invalid environment variable value for ${key}: must be a string`);
    }
    if (value.length > 10000) {
      throw new Error(`Invalid environment variable value for ${key}: exceeds maximum length of 10000 characters`);
    }
    validated[key] = value;
  }

  return validated;
}

/**
 * Redact sensitive values from environment variables for safe logging
 * @param env - Record of environment variables
 * @returns Record with sensitive values redacted
 */
export function logEnvironmentSafely(env: Record<string, string>): Record<string, string> {
  const safe: Record<string, string> = {};
  const sensitiveKeys = ['token', 'secret', 'password', 'api_key', 'key', 'auth', 'credential', 'private'];

  for (const [key, value] of Object.entries(env)) {
    const lowerKey = key.toLowerCase();
    if (sensitiveKeys.some(s => lowerKey.includes(s))) {
      safe[key] = '[REDACTED]';
    } else {
      // Truncate long values for logging
      safe[key] = value.length > 100 ? value.substring(0, 100) + '...' : value;
    }
  }

  return safe;
}
