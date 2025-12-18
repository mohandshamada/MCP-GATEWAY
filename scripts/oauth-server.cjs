#!/usr/bin/env node
/**
 * Simple OAuth2 Authorization Server for Testing
 *
 * This is a minimal OAuth2 server for testing the MCP Gateway OAuth integration.
 * DO NOT use this in production - use a proper OAuth provider like:
 * - Auth0 (https://auth0.com)
 * - Keycloak (https://keycloak.org)
 * - Okta (https://okta.com)
 * - AWS Cognito
 * - Azure AD
 *
 * Usage:
 *   node scripts/oauth-server.js [port]
 *
 * Default port: 9000
 *
 * Endpoints:
 *   POST /oauth/token     - Token endpoint (client_credentials grant)
 *   GET  /oauth/authorize - Authorization endpoint (for interactive flows)
 *   GET  /.well-known/openid-configuration - Discovery endpoint
 *   GET  /health          - Health check
 */

const http = require('http');
const crypto = require('crypto');
const url = require('url');

const PORT = process.argv[2] || 9000;

// In-memory client registry (in production, use a database)
const clients = {
  'mcp-gateway-client': {
    secret: 'mcp-gateway-secret',
    scopes: ['mcp:read', 'mcp:write', 'mcp:admin'],
    name: 'MCP Gateway'
  },
  'test-client': {
    secret: 'test-secret',
    scopes: ['read', 'write'],
    name: 'Test Client'
  }
};

// In-memory token store
const tokens = new Map();

// Generate a random token
function generateToken() {
  return crypto.randomBytes(32).toString('hex');
}

// Parse request body
function parseBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        if (req.headers['content-type']?.includes('application/json')) {
          resolve(JSON.parse(body));
        } else {
          // Parse URL-encoded form data
          resolve(Object.fromEntries(new URLSearchParams(body)));
        }
      } catch (e) {
        resolve({});
      }
    });
    req.on('error', reject);
  });
}

// Extract Basic Auth credentials
function extractBasicAuth(req) {
  const auth = req.headers['authorization'];
  if (!auth?.startsWith('Basic ')) return null;

  const decoded = Buffer.from(auth.slice(6), 'base64').toString();
  const [clientId, clientSecret] = decoded.split(':');
  return { clientId, clientSecret };
}

// Send JSON response
function sendJson(res, statusCode, data) {
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization'
  });
  res.end(JSON.stringify(data, null, 2));
}

// Handle token request
async function handleTokenRequest(req, res) {
  const body = await parseBody(req);
  const basicAuth = extractBasicAuth(req);

  // Get client credentials from Basic Auth or body
  const clientId = basicAuth?.clientId || body.client_id;
  const clientSecret = basicAuth?.clientSecret || body.client_secret;
  const grantType = body.grant_type;
  const scope = body.scope;

  console.log(`[OAuth] Token request: client=${clientId}, grant=${grantType}`);

  // Validate client
  const client = clients[clientId];
  if (!client || client.secret !== clientSecret) {
    console.log(`[OAuth] Invalid client credentials`);
    return sendJson(res, 401, {
      error: 'invalid_client',
      error_description: 'Invalid client credentials'
    });
  }

  // Handle grant types
  if (grantType === 'client_credentials') {
    const accessToken = generateToken();
    const expiresIn = 3600; // 1 hour

    // Store token
    tokens.set(accessToken, {
      clientId,
      scope: scope || client.scopes.join(' '),
      expiresAt: Date.now() + (expiresIn * 1000)
    });

    console.log(`[OAuth] Token issued for ${clientId}`);

    return sendJson(res, 200, {
      access_token: accessToken,
      token_type: 'Bearer',
      expires_in: expiresIn,
      scope: scope || client.scopes.join(' ')
    });
  }

  if (grantType === 'password') {
    const username = body.username;
    const password = body.password;

    // Simple password validation (in production, validate against user store)
    if (!username || !password) {
      return sendJson(res, 400, {
        error: 'invalid_request',
        error_description: 'Username and password required'
      });
    }

    const accessToken = generateToken();
    const refreshToken = generateToken();
    const expiresIn = 3600;

    tokens.set(accessToken, {
      clientId,
      username,
      scope: scope || client.scopes.join(' '),
      expiresAt: Date.now() + (expiresIn * 1000)
    });

    console.log(`[OAuth] Token issued for user ${username}`);

    return sendJson(res, 200, {
      access_token: accessToken,
      token_type: 'Bearer',
      expires_in: expiresIn,
      refresh_token: refreshToken,
      scope: scope || client.scopes.join(' ')
    });
  }

  if (grantType === 'refresh_token') {
    const refreshToken = body.refresh_token;

    if (!refreshToken) {
      return sendJson(res, 400, {
        error: 'invalid_request',
        error_description: 'Refresh token required'
      });
    }

    const accessToken = generateToken();
    const newRefreshToken = generateToken();
    const expiresIn = 3600;

    tokens.set(accessToken, {
      clientId,
      scope: scope || client.scopes.join(' '),
      expiresAt: Date.now() + (expiresIn * 1000)
    });

    console.log(`[OAuth] Token refreshed for ${clientId}`);

    return sendJson(res, 200, {
      access_token: accessToken,
      token_type: 'Bearer',
      expires_in: expiresIn,
      refresh_token: newRefreshToken,
      scope: scope || client.scopes.join(' ')
    });
  }

  return sendJson(res, 400, {
    error: 'unsupported_grant_type',
    error_description: `Grant type '${grantType}' not supported`
  });
}

// Handle discovery endpoint
function handleDiscovery(req, res) {
  const host = req.headers.host || `localhost:${PORT}`;
  const baseUrl = `http://${host}`;

  sendJson(res, 200, {
    issuer: baseUrl,
    authorization_endpoint: `${baseUrl}/oauth/authorize`,
    token_endpoint: `${baseUrl}/oauth/token`,
    token_endpoint_auth_methods_supported: ['client_secret_basic', 'client_secret_post'],
    grant_types_supported: ['client_credentials', 'password', 'refresh_token'],
    scopes_supported: ['mcp:read', 'mcp:write', 'mcp:admin', 'read', 'write'],
    response_types_supported: ['token']
  });
}

// Main request handler
const server = http.createServer(async (req, res) => {
  const parsedUrl = url.parse(req.url, true);
  const path = parsedUrl.pathname;

  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization'
    });
    return res.end();
  }

  console.log(`[OAuth] ${req.method} ${path}`);

  try {
    // Token endpoint
    if (path === '/oauth/token' && req.method === 'POST') {
      return await handleTokenRequest(req, res);
    }

    // Discovery endpoint
    if (path === '/.well-known/openid-configuration' && req.method === 'GET') {
      return handleDiscovery(req, res);
    }

    // Health check
    if (path === '/health' && req.method === 'GET') {
      return sendJson(res, 200, { status: 'healthy', service: 'oauth-server' });
    }

    // Authorization endpoint (simplified)
    if (path === '/oauth/authorize' && req.method === 'GET') {
      return sendJson(res, 200, {
        message: 'Authorization endpoint - redirect user here for interactive login',
        note: 'This test server only supports client_credentials grant'
      });
    }

    // 404 for unknown routes
    sendJson(res, 404, { error: 'not_found', message: 'Endpoint not found' });

  } catch (error) {
    console.error(`[OAuth] Error:`, error);
    sendJson(res, 500, { error: 'server_error', message: error.message });
  }
});

server.listen(PORT, () => {
  console.log('');
  console.log('='.repeat(60));
  console.log('  OAuth2 Test Authorization Server');
  console.log('='.repeat(60));
  console.log('');
  console.log(`  Server running on: http://localhost:${PORT}`);
  console.log('');
  console.log('  Endpoints:');
  console.log(`    POST http://localhost:${PORT}/oauth/token`);
  console.log(`    GET  http://localhost:${PORT}/.well-known/openid-configuration`);
  console.log(`    GET  http://localhost:${PORT}/health`);
  console.log('');
  console.log('  Test Clients:');
  console.log('    Client ID: mcp-gateway-client');
  console.log('    Client Secret: mcp-gateway-secret');
  console.log('');
  console.log('    Client ID: test-client');
  console.log('    Client Secret: test-secret');
  console.log('');
  console.log('  Example token request:');
  console.log(`    curl -X POST http://localhost:${PORT}/oauth/token \\`);
  console.log('      -H "Content-Type: application/x-www-form-urlencoded" \\');
  console.log('      -d "grant_type=client_credentials" \\');
  console.log('      -d "client_id=mcp-gateway-client" \\');
  console.log('      -d "client_secret=mcp-gateway-secret"');
  console.log('');
  console.log('='.repeat(60));
  console.log('');
});
