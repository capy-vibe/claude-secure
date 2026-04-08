const http = require('http');
const https = require('https');
const fs = require('fs');

const UPSTREAM = process.env.REAL_ANTHROPIC_BASE_URL || 'https://api.anthropic.com';
const WHITELIST_PATH = process.env.WHITELIST_PATH || '/etc/claude-secure/whitelist.json';
const warnedEnvVars = new Set();

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
  }

  // Sort by search string length, longest first to prevent partial match corruption
  redactMap.sort((a, b) => b[0].length - a[0].length);
  restoreMap.sort((a, b) => b[0].length - a[0].length);

  return { redactMap, restoreMap };
}

function applyReplacements(text, pairs) {
  if (!text) return text;
  let result = text;
  for (const [search, replace] of pairs) {
    result = result.replaceAll(search, replace);
  }
  return result;
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
    // Load config fresh on each request (SECR-04)
    const config = loadWhitelist();
    if (!config) {
      res.writeHead(500, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'Proxy configuration error', detail: 'Failed to load whitelist config' }));
      return;
    }

    // Build replacement maps from config + env vars
    const { redactMap, restoreMap } = buildMaps(config);

    // Redact secrets in outbound request body (SECR-02)
    const redactedBody = applyReplacements(body, redactMap);

    // Parse upstream URL
    const url = new URL(req.url, UPSTREAM);

    // Prepare headers with auth and recalculated Content-Length (SECR-05, D-10)
    const headers = prepareHeaders(req.headers, Buffer.byteLength(redactedBody));
    headers['host'] = url.host;

    // Forward to Anthropic
    const upstreamReq = https.request({
      hostname: url.hostname,
      port: 443,
      path: url.pathname + url.search,
      method: req.method,
      headers
    }, upstreamRes => {
      let responseBody = '';
      upstreamRes.on('data', chunk => { responseBody += chunk; });
      upstreamRes.on('end', () => {
        // Restore placeholders to real values in response (SECR-03)
        const restoredBody = applyReplacements(responseBody, restoreMap);

        // Build response headers with recalculated Content-Length
        const resHeaders = { ...upstreamRes.headers };
        resHeaders['content-length'] = String(Buffer.byteLength(restoredBody));
        delete resHeaders['transfer-encoding'];

        res.writeHead(upstreamRes.statusCode, resHeaders);
        res.end(restoredBody);
      });
    });

    upstreamReq.on('error', err => {
      console.error('Upstream error:', err.message);
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'Bad Gateway', detail: err.message }));
    });

    upstreamReq.write(redactedBody);
    upstreamReq.end();
  });
});

const PORT = process.env.PROXY_PORT || 8080;
console.log('Whitelist path: ' + WHITELIST_PATH);
console.log('Auth: ' + (process.env.CLAUDE_CODE_OAUTH_TOKEN ? 'OAuth' : process.env.ANTHROPIC_API_KEY ? 'API key' : 'NONE'));
server.listen(PORT, '0.0.0.0', () => {
  console.log('Proxy listening on :' + PORT);
});
