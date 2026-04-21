// nanostack-telemetry Worker
//
// Security contract (audited against TELEMETRY.md). Any change here must keep
// these invariants. The Worker CI lint enforces the marker comments.
//
//   1. HTTPS_ENFORCED: non-HTTPS requests return 400 immediately.
//   2. SCHEMA_STRICT:  only TELEMETRY_FIELDS_V1 survive validation. Unknown
//                      fields are dropped before insertion. Wrong types reject.
//   3. IP_NEVER_STORED: the raw CF-Connecting-IP is read only to compute a
//                      daily-rotating hash used for rate-limit counting. The
//                      hash is stored in KV with a short TTL; the raw IP is
//                      never written to D1 or logged.
//   4. NO_BODY_LOGGING: nothing in this file calls console.log/debug/info on
//                      the request body, headers, or any derived content.
//                      Only shape metrics (status codes, counts) are logged.

export interface Env {
  DB: D1Database;
  RATE_LIMIT: KVNamespace;
  MASTER_SALT: string;
}

// TELEMETRY_FIELDS_V1: v ts skill session_id nanostack_version os arch duration_s outcome error_class installation_id
// (kept in a comment so CI can verify client and server share the same list.)

const MAX_PAYLOAD_BYTES = 50_000;
const MAX_BATCH_SIZE = 100;
const RATE_LIMIT_PER_MIN = 100;

const ALLOWED_OS = new Set(["darwin", "linux", "unknown"]);
const ALLOWED_ARCH = new Set(["x86_64", "arm64", "unknown"]);
const ALLOWED_OUTCOME = new Set(["success", "error", "abort", "unknown"]);
const ALLOWED_ERROR_CLASS = new Set([
  "phase_timeout",
  "save_failed",
  "lint_error",
  "resolver_error",
  "budget_exceeded",
  "user_abort",
  "other",
]);

interface TelemetryEvent {
  v: number;
  ts: string;
  skill: string;
  session_id?: string | null;
  nanostack_version?: string | null;
  os?: string | null;
  arch?: string | null;
  duration_s?: number | null;
  outcome: string;
  error_class?: string | null;
  installation_id?: string | null;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // HTTPS_ENFORCED
    const url = new URL(request.url);
    if (url.protocol !== "https:") {
      return new Response("HTTPS required", { status: 400 });
    }

    // Method gate.
    if (request.method !== "POST") {
      // Health/liveness probes hit GET /; answer lightly without leaking info.
      if (request.method === "GET" && url.pathname === "/") {
        return new Response("ok\n", {
          status: 200,
          headers: { "Content-Type": "text/plain" },
        });
      }
      return new Response("POST required", {
        status: 405,
        headers: { Allow: "POST" },
      });
    }

    // Route. Only /v1/event accepts payloads.
    if (url.pathname !== "/v1/event") {
      return new Response("Not found", { status: 404 });
    }

    // Content-Type gate. Prevents form-encoded or multipart surprises.
    const contentType = request.headers.get("content-type") || "";
    if (!contentType.toLowerCase().startsWith("application/json")) {
      return new Response("application/json required", { status: 415 });
    }

    // Payload size gate (pre-parse). CF already caps at 100MB but we cap at 50KB.
    const contentLength = parseInt(request.headers.get("content-length") || "0", 10);
    if (contentLength > MAX_PAYLOAD_BYTES) {
      return new Response("Payload too large", { status: 413 });
    }

    // Rate limit (pre-parse, cheap). IP_NEVER_STORED: we hash + KV-cache only.
    const clientIp = request.headers.get("CF-Connecting-IP") || "unknown";
    const rlKey = await rateLimitKey(clientIp, env.MASTER_SALT);
    const current = parseInt((await env.RATE_LIMIT.get(rlKey)) || "0", 10);
    if (current >= RATE_LIMIT_PER_MIN) {
      return new Response("Rate limit exceeded", {
        status: 429,
        headers: { "Retry-After": "60" },
      });
    }
    // Increment with 70s TTL. Eventually consistent; acceptable for rate limiting.
    await env.RATE_LIMIT.put(rlKey, String(current + 1), { expirationTtl: 70 });

    // Parse body. Any parse error → 400, no body echoed.
    let body: unknown;
    try {
      const text = await request.text();
      if (text.length > MAX_PAYLOAD_BYTES) {
        return new Response("Payload too large", { status: 413 });
      }
      body = JSON.parse(text);
    } catch {
      return new Response("Invalid JSON", { status: 400 });
    }

    const events: unknown[] = Array.isArray(body) ? body : [body];
    if (events.length === 0) {
      return new Response(JSON.stringify({ inserted: 0 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    if (events.length > MAX_BATCH_SIZE) {
      return new Response(`Batch too large (max ${MAX_BATCH_SIZE})`, {
        status: 400,
      });
    }

    // SCHEMA_STRICT: validate each event, drop malformed, reject if all malformed.
    const rows: TelemetryEvent[] = [];
    for (const e of events) {
      const validated = validateEvent(e);
      if (validated) rows.push(validated);
    }

    if (rows.length === 0) {
      return new Response(JSON.stringify({ inserted: 0, rejected: events.length }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Insert with parameterized prepared statements. Never build SQL from input.
    const stmt = env.DB.prepare(
      `INSERT INTO events
         (event_ts, skill, outcome, duration_s, nanostack_version,
          os, arch, installation_id, session_id, error_class)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    );
    const batch = rows.map((r) =>
      stmt.bind(
        r.ts,
        r.skill,
        r.outcome,
        r.duration_s ?? null,
        r.nanostack_version ?? null,
        r.os ?? null,
        r.arch ?? null,
        r.installation_id ?? null,
        r.session_id ?? null,
        r.error_class ?? null,
      ),
    );

    try {
      await env.DB.batch(batch);
    } catch {
      // Do not echo error detail. A failed insert tells the client to retry.
      return new Response(JSON.stringify({ error: "insert_failed" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(
      JSON.stringify({ inserted: rows.length, rejected: events.length - rows.length }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  },
};

// SCHEMA_STRICT: return null on any schema deviation. Unknown fields are
// ignored (not stored, not echoed). Enums collapse to safe defaults at the
// client level already; here we defense-in-depth reject anything that slipped.
function validateEvent(raw: unknown): TelemetryEvent | null {
  if (!raw || typeof raw !== "object") return null;
  const e = raw as Record<string, unknown>;

  if (e.v !== 1) return null;
  if (typeof e.ts !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(e.ts)) return null;
  if (typeof e.skill !== "string" || e.skill.length === 0 || e.skill.length > 50) return null;
  if (typeof e.outcome !== "string" || !ALLOWED_OUTCOME.has(e.outcome)) return null;

  const os = typeof e.os === "string" ? e.os : null;
  if (os !== null && !ALLOWED_OS.has(os)) return null;

  const arch = typeof e.arch === "string" ? e.arch : null;
  if (arch !== null && !ALLOWED_ARCH.has(arch)) return null;

  const errorClass = typeof e.error_class === "string" ? e.error_class : null;
  if (errorClass !== null && !ALLOWED_ERROR_CLASS.has(errorClass)) return null;

  // duration_s: integer seconds, bounded.
  let duration: number | null = null;
  if (typeof e.duration_s === "number") {
    if (!Number.isFinite(e.duration_s) || e.duration_s < 0 || e.duration_s > 86400) return null;
    duration = Math.floor(e.duration_s);
  }

  // Version + installation_id + session_id: caps on length, no content inspection.
  const version = typeof e.nanostack_version === "string" ? e.nanostack_version.slice(0, 32) : null;
  if (version !== null && !/^[0-9A-Za-z._-]+$/.test(version)) return null;

  const installId = typeof e.installation_id === "string" ? e.installation_id.slice(0, 64) : null;
  if (installId !== null && !/^[0-9a-f-]{36}$/.test(installId)) return null;

  const sessionId = typeof e.session_id === "string" ? e.session_id.slice(0, 64) : null;
  if (sessionId !== null && !/^[0-9]+-[0-9]+$/.test(sessionId)) return null;

  return {
    v: 1,
    ts: e.ts,
    skill: e.skill.slice(0, 50),
    outcome: e.outcome,
    os,
    arch,
    error_class: errorClass,
    duration_s: duration,
    nanostack_version: version,
    installation_id: installId,
    session_id: sessionId,
  };
}

// rateLimitKey computes sha256(ip || daily_salt || minute_bucket). The per-minute
// bucket means the counter auto-expires; the daily salt means yesterday's hashes
// are uncorrelatable with today's. MASTER_SALT is a Worker secret, not in git.
async function rateLimitKey(ip: string, masterSalt: string): Promise<string> {
  const now = new Date();
  const dateKey =
    now.getUTCFullYear().toString() +
    String(now.getUTCMonth() + 1).padStart(2, "0") +
    String(now.getUTCDate()).padStart(2, "0");
  const minuteKey = dateKey + String(now.getUTCHours()).padStart(2, "0") + String(now.getUTCMinutes()).padStart(2, "0");
  const input = `${ip}|${masterSalt}|${dateKey}`;
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const hex = Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `rl:${hex}:${minuteKey}`;
}
