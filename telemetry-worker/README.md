# nanostack-telemetry Worker

Cloudflare Worker that ingests opt-in telemetry events from nanostack clients.
Strict by construction: HTTPS-only, schema-whitelisted, rate-limited, never
stores raw IP, never logs request bodies.

Privacy contract is documented at `../TELEMETRY.md`. This README covers
deployment and operations only. If a claim in this folder conflicts with
`TELEMETRY.md`, the contract wins.

## Layout

```
telemetry-worker/
  src/index.ts          Worker code (validate + insert + rate limit)
  migrations/0001_init.sql  D1 schema
  wrangler.toml         CF bindings
  verify-security.sh    Adversarial smoke tests against a deployed endpoint
  package.json
  tsconfig.json
  README.md
```

## One-time setup (maintainer)

Prereqs: `bunx wrangler@latest login` against the account that owns
`nanostack-telemetry.remoto.workers.dev`.

```sh
cd telemetry-worker

# 1. Create the D1 database. Copy the printed database_id into wrangler.toml.
bunx wrangler@latest d1 create nanostack-telemetry

# 2. Apply the schema.
bunx wrangler@latest d1 execute nanostack-telemetry --remote --file=migrations/0001_init.sql

# 3. Create the KV namespace for rate limiting. Copy the id into wrangler.toml.
bunx wrangler@latest kv namespace create rate-limit

# 4. Set the daily-salt secret. Pick any 32+ char random value; it never
#    leaves the Worker runtime. Rotate whenever you want to guarantee no
#    cross-day hash correlation.
openssl rand -hex 32 | bunx wrangler@latest secret put MASTER_SALT

# 5. Deploy.
bunx wrangler@latest deploy
```

After step 5, `https://nanostack-telemetry.remoto.workers.dev/` returns `ok`.

## Verifying the security contract

Run the adversarial smoke tests against the live endpoint:

```sh
./verify-security.sh
```

The script exits non-zero if any assertion fails. It covers:

- HTTP (non-TLS) request → 400
- Wrong method → 405
- Wrong Content-Type → 415
- Oversized payload → 413
- Oversized batch → 400
- Wrong schema version → rejected
- Unknown fields → dropped, not persisted
- Prompt-injection-like strings in fields → rejected by enum validation

## Routing summary

```
GET  /           200 "ok"       (liveness probe)
POST /v1/event   200 { inserted, rejected }   on success
POST /v1/event   4xx             on schema / size / auth / rate-limit failures
any other        404
```

## Invariants the CI lint enforces

Looks in `src/index.ts` for the marker comments:

- `HTTPS_ENFORCED`   — non-HTTPS must return 400.
- `SCHEMA_STRICT`    — only TELEMETRY_FIELDS_V1 survive validation.
- `IP_NEVER_STORED`  — raw IP never written to D1; only hashed for rate limit.
- `NO_BODY_LOGGING`  — no console.log on request body, headers, or derived content.

Removing any of these invariants breaks the CI job `telemetry-worker-privacy`.

## Operating notes

- **Logs.** `bunx wrangler tail` streams live logs. Only method, path, status,
  and derived counts appear. No body, no headers beyond Content-Type.
- **D1 retention.** 90 days of raw events. A cron job (separate, not in this
  PR) aggregates older rows into daily per-skill counts and drops
  installation_id + session_id at aggregation.
- **Rate limit.** Per-IP-hash, per-minute. KV TTL 70s. Exceeding 100 req/min
  returns 429 with `Retry-After: 60`.
- **Salt rotation.** The daily salt derives from `MASTER_SALT || YYYYMMDD`.
  To force-rotate, set a new `MASTER_SALT` with `wrangler secret put`.
  Rotating invalidates all prior rate-limit counters; fine.

## Known non-goals

- No authentication. The endpoint accepts anonymous POSTs on purpose; adding
  an API key would create a credential that leaks to any disassembled client.
- No CORS. The endpoint is not intended for browsers.
- No GraphQL, no batch beyond 100, no streaming, no websockets.
