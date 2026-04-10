const http = require('http');
const https = require('https');
const net = require('net');
const dns = require('dns');
const fs = require('fs');

const UPSTREAM = process.env.REAL_ANTHROPIC_BASE_URL || 'https://api.anthropic.com';
const WHITELIST_PATH = process.env.WHITELIST_PATH || '/etc/claude-secure/whitelist.json';
const warnedEnvVars = new Set();

const LOG_PATH = '/var/log/claude-secure/anthropic.jsonl';
const LOG_ENABLED = process.env.LOG_ANTHROPIC === '1';

function logJson(level, msg, extra) {
  if (!LOG_ENABLED) return;
  try {
    const entry = JSON.stringify({
      ts: new Date().toISOString(),
      svc: 'anthropic',
      level,
      msg,
      ...extra
    }) + '\n';
    fs.appendFileSync(LOG_PATH, entry);
  } catch (e) {
    // Silently ignore log write failures
  }
}

// External DNS resolver to bypass Docker network aliases (which map api.anthropic.com to this proxy)
const externalResolver = new dns.Resolver();
externalResolver.setServers(['8.8.8.8', '1.1.1.1']);

function loadWhitelist() {
  try {
    const raw = fs.readFileSync(WHITELIST_PATH, 'utf8');
    return JSON.parse(raw);
  } catch (err) {
    console.error('Failed to load whitelist: ' + err.message);
    return null;
  }
}

function buildMaps(config) {
  const redactMap = [];
  const restoreMap = [];
  const logPairs = [];

  for (const entry of config.secrets || []) {
    const realValue = process.env[entry.env_var];
    if (!realValue) {
      if (!warnedEnvVars.has(entry.env_var)) {
        console.warn('Secret env var not set: ' + entry.env_var);
        warnedEnvVars.add(entry.env_var);
      }
      continue;
    }
    redactMap.push([realValue, entry.placeholder]);
    restoreMap.push([entry.placeholder, realValue]);
    logPairs.push({
      masked: realValue.slice(0, Math.min(8, Math.floor(realValue.length / 3))) + '...',
      placeholder: entry.placeholder,
      env_var: entry.env_var
    });
  }

  // Sort by search string length, longest first to prevent partial match corruption
  redactMap.sort((a, b) => b[0].length - a[0].length);
  restoreMap.sort((a, b) => b[0].length - a[0].length);

  return { redactMap, restoreMap, logPairs };
}

function applyReplacements(text, pairs) {
  if (!text) return text;
  let result = text;
  for (const [search, replace] of pairs) {
    result = result.replaceAll(search, replace);
  }
  return result;
}

function isDomainAllowed(domain, config) {
  if (!config) return false;
  for (const entry of config.secrets || []) {
    for (const d of entry.allowed_domains || []) {
      if (domain === d || domain.endsWith('.' + d)) return true;
    }
  }
  for (const d of config.readonly_domains || []) {
    if (domain === d || domain.endsWith('.' + d)) return true;
  }
  return false;
}

function prepareHeaders(incomingHeaders, bodyByteLength) {
  const headers = { ...incomingHeaders };

  // Remove Claude container's auth headers (D-08)
  delete headers['x-api-key'];
  delete headers['authorization'];
  delete headers['anthropic-api-key'];

  // Strip accept-encoding to prevent compressed responses from Anthropic
  delete headers['accept-encoding'];

  // Set proxy's own auth credentials (D-09: OAuth preferred over API key)
  const oauthToken = process.env.CLAUDE_CODE_OAUTH_TOKEN;
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (oauthToken) {
    headers['authorization'] = 'Bearer ' + oauthToken;
  } else if (apiKey) {
    headers['x-api-key'] = apiKey;
  }

  // Recalculate Content-Length after body transformation (D-10)
  headers['content-length'] = String(bodyByteLength);

  return headers;
}

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    const startTime = Date.now();
    // Load config fresh on each request (SECR-04)
    const config = loadWhitelist();
    if (!config) {
      logJson('error', 'Failed to load whitelist config');
      res.writeHead(500, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'Proxy configuration error', detail: 'Failed to load whitelist config' }));
      return;
    }

    // Detect forward proxy mode (full URL) vs reverse proxy mode (path only)
    const isForwardProxy = req.url.startsWith('http://') || req.url.startsWith('https://');
    const url = new URL(req.url, UPSTREAM);

    // For forward proxy requests, validate domain against whitelist
    if (isForwardProxy && !isDomainAllowed(url.hostname, config)) {
      console.warn('Forward proxy blocked: ' + url.hostname + ' (not in whitelist)');
      logJson('warn', 'Blocked request to non-whitelisted domain', { method: req.method, domain: url.hostname });
      res.writeHead(403, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'Forbidden', detail: 'Domain not in whitelist: ' + url.hostname }));
      return;
    }

    // Build replacement maps from config + env vars
    const { redactMap, restoreMap, logPairs } = buildMaps(config);

    // Log active redaction mappings (masked prefixes only, never full secrets)
    if (logPairs.length > 0) {
      logJson('info', 'Active redaction mappings', { redaction_map: logPairs });
    }

    // Redact secrets in outbound request body (SECR-02)
    // For forward proxy to external services, redaction prevents accidental secret leakage
    const redactedBody = isForwardProxy ? body : applyReplacements(body, redactMap);

    // Prepare headers: only inject proxy auth for Anthropic (reverse proxy) requests
    const headers = isForwardProxy
      ? { ...req.headers, host: url.host, 'content-length': String(Buffer.byteLength(redactedBody)) }
      : prepareHeaders(req.headers, Buffer.byteLength(redactedBody));
    if (!isForwardProxy) headers['host'] = url.host;

    // Forward to upstream
    const isHttps = url.protocol === 'https:';
    const transport = isHttps ? https : http;

    const doRequest = (resolvedHostname) => {
      const upstreamReq = transport.request({
        hostname: resolvedHostname,
        port: url.port || (isHttps ? 443 : 80),
        path: url.pathname + url.search,
        method: req.method,
        headers,
        servername: url.hostname  // SNI must use original hostname for TLS
      }, upstreamRes => {
      let responseBody = '';
      upstreamRes.on('data', chunk => { responseBody += chunk; });
      upstreamRes.on('end', () => {
        // Restore placeholders to real values in response (SECR-03, reverse proxy only)
        const restoredBody = isForwardProxy ? responseBody : applyReplacements(responseBody, restoreMap);

        // Build response headers with recalculated Content-Length
        const resHeaders = { ...upstreamRes.headers };
        resHeaders['content-length'] = String(Buffer.byteLength(restoredBody));
        delete resHeaders['transfer-encoding'];

        res.writeHead(upstreamRes.statusCode, resHeaders);
        res.end(restoredBody);
        logJson('info', 'Forwarded request to upstream', { method: req.method, path: url.pathname, redacted: redactMap.length, status: upstreamRes.statusCode, duration_ms: Date.now() - startTime });
      });
    });

      upstreamReq.on('error', err => {
        console.error('Upstream error:', err.message);
        logJson('error', 'Upstream request failed', { method: req.method, path: url.pathname, error: err.message });
        res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'Bad Gateway', detail: err.message }));
      });

      upstreamReq.write(redactedBody);
      upstreamReq.end();
    };

    // For reverse proxy (Anthropic API): resolve via external DNS to bypass Docker alias
    // For forward proxy: use hostname directly (already resolved correctly)
    if (!isForwardProxy) {
      externalResolver.resolve4(url.hostname, (err, addresses) => {
        if (err || !addresses.length) {
          console.error('DNS resolution failed for ' + url.hostname + ': ' + (err ? err.message : 'no addresses'));
          res.writeHead(502, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'Bad Gateway', detail: 'DNS resolution failed for ' + url.hostname }));
          return;
        }
        doRequest(addresses[0]);
      });
    } else {
      doRequest(url.hostname);
    }
  });
});

// HTTPS CONNECT tunneling for forward proxy (HTTP_PROXY/HTTPS_PROXY)
server.on('connect', (req, clientSocket, head) => {
  const [hostname, port] = req.url.split(':');
  const config = loadWhitelist();

  if (!isDomainAllowed(hostname, config)) {
    console.warn('CONNECT blocked: ' + hostname + ' (not in whitelist)');
    logJson('warn', 'Blocked CONNECT to non-whitelisted domain', { domain: hostname });
    clientSocket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
    clientSocket.end();
    return;
  }

  const serverSocket = net.connect(parseInt(port) || 443, hostname, () => {
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    serverSocket.write(head);
    serverSocket.pipe(clientSocket);
    clientSocket.pipe(serverSocket);
  });

  serverSocket.on('error', err => {
    console.error('CONNECT error to ' + hostname + ': ' + err.message);
    clientSocket.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
    clientSocket.end();
  });

  clientSocket.on('error', () => serverSocket.destroy());
});

const PORT = process.env.PROXY_PORT || 8080;
const TLS_PORT = 443;
console.log('Whitelist path: ' + WHITELIST_PATH);
console.log('Auth: ' + (process.env.CLAUDE_CODE_OAUTH_TOKEN ? 'OAuth' : process.env.ANTHROPIC_API_KEY ? 'API key' : 'NONE'));
server.listen(PORT, '0.0.0.0', () => {
  console.log('Proxy listening on :' + PORT);
});

// HTTPS listener for intercepted hardcoded calls to api.anthropic.com
// (routed here via Docker network alias — Claude Code bypasses ANTHROPIC_BASE_URL for some calls)
try {
  const tlsOpts = {
    key: fs.readFileSync('/app/key.pem'),
    cert: fs.readFileSync('/app/cert.pem'),
  };
  const tlsServer = https.createServer(tlsOpts, server._events.request);
  tlsServer.listen(TLS_PORT, '0.0.0.0', () => {
    console.log('Proxy (TLS) listening on :' + TLS_PORT);
  });
} catch (err) {
  console.warn('TLS listener not started (certs missing): ' + err.message);
}
