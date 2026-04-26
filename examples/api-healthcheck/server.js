// server.js — minimal HTTP server for the api-healthcheck example.
//
// One endpoint: GET /health returns {"status":"ok","ts":"..."}.
// Everything else returns 404. Zero dependencies, single file,
// stdlib only. The point is not the server. It is having a real
// HTTP surface to run a full nanostack sprint on without touching
// any project that matters.
//
// Usage:
//   node server.js               start on PORT (default 3000)
//   PORT=4000 node server.js     start on a different port
//
// Verify by hand once running:
//   curl -s http://localhost:3000/health
//   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/missing
//
// The gaps (no version endpoint, no request log, no readiness
// probe) are the seeds for your first nanostack sprint. See
// README.md for three concrete feature ideas.
'use strict';

const http = require('http');

const PORT = parseInt(process.env.PORT || '3000', 10);
const STARTED_AT = new Date().toISOString();

function reply(res, status, body) {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(json),
    'Cache-Control': 'no-store'
  });
  res.end(json);
}

const server = http.createServer((req, res) => {
  if (req.method !== 'GET') {
    return reply(res, 405, { error: 'method_not_allowed' });
  }

  switch (req.url) {
    case '/health':
      return reply(res, 200, {
        status: 'ok',
        ts: new Date().toISOString(),
        started_at: STARTED_AT
      });
    default:
      return reply(res, 404, { error: 'not_found' });
  }
});

server.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`api-healthcheck listening on http://localhost:${PORT}`);
});

// Graceful shutdown on Ctrl-C / SIGTERM so the example does not
// leave dangling sockets if the user runs it under a process
// supervisor.
['SIGINT', 'SIGTERM'].forEach((sig) => {
  process.on(sig, () => {
    server.close(() => process.exit(0));
  });
});
