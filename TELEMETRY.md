# Telemetry

**TL;DR.** nanostack has opt-in telemetry about skill usage. Three tiers: `off`, `anonymous`, `community`. Default is `off`; you must opt in explicitly. Opt out any time with `nanostack-config set telemetry off`. The client writes events locally to `~/.nanostack/` regardless; a Cloudflare Worker at `nanostack-telemetry.remoto.workers.dev` accepts opt-in uploads and is the only network endpoint involved. Source of the Worker lives in this repo under `telemetry-worker/`.

This document is the source of truth for what we collect, why, and how to audit it. If you find a gap between this file and the code, that is a bug; open an issue.

## How to turn it off

One command, any time:

```sh
nanostack-config set telemetry off
```

That is it. No reboot, no reinstall, no follow-up. The next skill you run will not write any event. To also delete the local log of past events:

```sh
nanostack-config clear-data
```

If nanostack was already installed on your system before this feature existed, your tier defaults to `off` and you see no prompt. You do not have to do anything.

## Why this exists

Without usage data we cannot tell which skills are used most, where sprints abort, which `error_class` shows up in production, or which nanostack version is in the wild. Every prioritization decision becomes gut feel. Opt-in telemetry answers the questions that shape what gets fixed next.

### What your opt-in answers

- Which skill is the entry point for most sprints.
- What percentage of `/think` sprints reach `/ship`. If half abort before shipping, something upstream is wrong.
- Which `error_class` shows up most often. That is the next bug to fix.
- Which versions are running. Critical for deciding when to deprecate a behavior.
- Whether any users actually run nanostack in Alpine, slim Docker, or older macOS.

The difference between the two opt-in tiers:

- **Anonymous** answers "how many people use X". Enough to prioritize.
- **Community** answers "do people who use X also use Y, and in what order". Better for understanding real workflows and catching regressions that only show up in specific sequences.

Neither tier reveals who you are or what you are building. You pick which question you are willing to help answer.

## The three tiers

When a new installation first runs any skill, nanostack prompts once. The choice persists in `~/.nanostack/user-config.json`.

| Tier | Local write | Remote send | Notes |
|---|---|---|---|
| `off` | Nothing | Nothing | No JSONL file is created. |
| `anonymous` | Full event | Same event minus `session_id` and `installation_id` | Server sees unlinked events. Cannot tie two events together. |
| `community` | Full event | Full event including `session_id` and `installation_id` | Server can see flow within one sprint and across sprints of the same installation. Installation identity is a random UUID with no tie to your machine, name, or account. |

Change tier at any time:

```sh
nanostack-config set telemetry off
nanostack-config set telemetry anonymous
nanostack-config set telemetry community
```

## Schema v1 (frozen)

Every recorded event is one JSON object on one line in `~/.nanostack/analytics/skill-usage.jsonl`. Schema v1 is frozen. Future versions add fields; they never rename, remove, or repurpose.

```json
{
  "v": 1,
  "ts": "2026-04-21T12:00:00Z",
  "skill": "think",
  "session_id": "12345-1776747000",
  "nanostack_version": "0.5.0",
  "os": "darwin",
  "arch": "arm64",
  "duration_s": 180,
  "outcome": "success",
  "error_class": null,
  "installation_id": "a3f7c2e1-4b9d-4e8a-b21c-d8f92c4a7e1b"
}
```

Field by field:

| Field | Type | Why | Collected when |
|---|---|---|---|
| `v` | int | Schema version. Enables forward-compatible changes. | always |
| `ts` | ISO-8601 UTC | When the skill finished. Rounded to the second. | always |
| `skill` | string | Which skill ran. This is the primary signal. | always |
| `session_id` | string | Links events within one sprint. `$PID-$EPOCH`. Never crosses sprints. | always locally; community only remotely |
| `nanostack_version` | string | Version of the installed skill. Helps us triage by release. | always |
| `os` | enum `darwin`, `linux`, `unknown` | Portability signal. Any other value collapses to `unknown`. | always |
| `arch` | enum `x86_64`, `arm64`, `unknown` | Portability signal. Any other value collapses to `unknown`. | always |
| `duration_s` | int seconds or null | Performance signal. Rounded to the second, never milliseconds. | when computable |
| `outcome` | enum `success`, `error`, `abort`, `unknown` | Success rate metric. | always |
| `error_class` | enum from a whitelist or `other`, or null | Triage signal. Whitelist prevents leaking error strings. | when outcome is `error` |
| `installation_id` | UUID v4 or null | Stable identity for the installation, random, not derived. | community tier only |

The enum whitelists are enforced in `bin/lib/telemetry.sh` and checked by CI. Any value outside the enum collapses to the fallback (`unknown`, `other`). This guards against accidental leakage of a string that contains user-specific information.

## How anonymization works

Three mechanisms, applied at different points in the pipeline.

### 1. Identity-free by construction

The fields we collect are deliberately chosen to be non-identifying. `skill`, `duration_s`, `outcome`, `os`, `arch`, `nanostack_version`. None of these say anything about who you are. They are the minimum needed to answer aggregate questions about how nanostack is used.

Fields that would identify you (hostname, username, repo name, branch, file paths, code, prompts, LLM responses) are never read by the telemetry code. This is enforced by a CI grep on every PR. If a contributor tries to add one, the build fails before the code can be merged.

### 2. installation_id is not a fingerprint

When you opt into `community`, nanostack generates a UUID v4 at `~/.nanostack/installation-id`. Three properties worth stating:

- **Random, not derived.** It has no mathematical relationship to your hostname, username, MAC address, or any other machine identifier. Two laptops on the same network get different UUIDs. The same laptop, if you delete the file and regenerate, gets a different UUID.
- **Not joinable.** There is no external registry. nanostack has no email, no GitHub account, no signup. Nothing maps the UUID back to you as a person.
- **Local until you send it.** On `anonymous` or `off`, the UUID either does not exist or is not transmitted. A local file alone is not surveillance.

Source of randomness, in priority order: `uuidgen`, `/proc/sys/kernel/random/uuid`, then `od -tx1 -N16 /dev/urandom` with manual v4/variant bit formatting. All three produce a standard RFC 4122 UUID v4 with 122 bits of entropy.

The file is stored at `~/.nanostack/installation-id`, mode `0600`, one line, raw UUID.

To rotate your UUID at any time:

```sh
nanostack-config set telemetry off
nanostack-config set telemetry community
```

### 3. Network-layer anonymization (server-side)

The Worker hashes your IP with a salt that rotates every 24 hours and keeps only the hash in KV with a 70-second TTL for rate limiting. The raw IP is never written to the database and never logged. Because the salt rotates daily, yesterday's hash of your IP does not match today's hash. An attacker who dumps the database cannot correlate your events across days, even if your network location never changed.

Worker source: `telemetry-worker/src/index.ts`. The `rateLimitKey` function is the only place that touches the raw IP; see the `IP_NEVER_STORED` marker comment.

### What anonymization does NOT cover

Being honest about the limits: anonymization is about the data we collect and store, not about the fact that a request happens. Your ISP and your local DNS resolver see that your machine talks to `nanostack-telemetry.remoto.workers.dev`. That visibility is inherent to any network call and we cannot hide it. If it is unacceptable for your threat model, the only safe tier is `off`.

## What is NEVER collected

Hard rule. If a field is not in the schema above, it does not appear in the JSONL, is not sent over the network, and is not processed in any way.

- Prompts, briefs, LLM responses, or any text the user or model generated.
- File paths, file names, file contents.
- Repository names, branch names, commit hashes, commit messages, remote URLs.
- Hostname, username, MAC address, UID, GID.
- IP address in any usable form. The Worker hashes IPs with a daily-rotating salt for rate limiting only; neither the raw IP nor the hash is persisted.
- Email, auth tokens, account identifiers, third-party service IDs.
- Environment variables, shell history, process lists.
- Cookies, browser fingerprints, device identifiers beyond the random UUID.
- Keystrokes, clipboard, screen contents, any kind of session replay.

CI lint fails any PR that adds a field not declared here or introduces a pattern that reads any of the above into the telemetry path.

## What a leak looks like

If a mistake exposes the Worker's D1 database, the worst case is a dump of event records. What that dump shows:

- Aggregate counts per skill, per version, per OS, per week.
- Per-installation sequences of events. Example: installation `a3f7c2e1` ran `/think` at 12:00, `/nano` at 12:03, aborted `/review` at 12:07, reported `error_class=lint_error`.
- No way to map installation UUIDs to human identities, email addresses, or source code.

That is embarrassing, not catastrophic. It does not reveal what users are building, who they are, or where their code lives.

## How to inspect your own data

Everything is local and human-readable. Remote uploads, when you opt into them, send exactly what `show-data --remote-preview` prints. Commands:

```sh
# show current tier, installation-id, data directory
nanostack-config get all

# show the last 20 events, pretty-printed
nanostack-config show-data

# show everything
nanostack-config show-data --full

# dry-run: what would be sent if tier were not off
# (tier-aware: anonymous drops session_id and installation_id)
nanostack-config show-data --remote-preview

# summary: tier, event count, top skills last 30 days
nanostack-config status

# delete the local log (irreversible)
nanostack-config clear-data
```

For paranoid live inspection, set the debug flag and watch stderr:

```sh
NANO_TEL_DEBUG=1 /think "some idea"
# each event is printed to stderr before it is written to disk
```

## How to verify we are not lying

The source of truth is the code. Three checks:

1. `bin/lib/telemetry.sh` contains every function that can write to the JSONL or read from system state. Grep it for `HOSTNAME`, `USER`, `git remote`, `git branch`, `basename $PWD`, or any path reading that is not part of the enum fallback. You should find none.
2. `.github/workflows/lint.yml` has a `telemetry-privacy` job that runs on every PR. It fails if new code introduces any of the patterns above, and it fails if a field appears in `telemetry.sh` that is not declared in this document.
3. The Cloudflare Worker source lives at `telemetry-worker/src/index.ts`. The endpoint validates incoming events against a strict whitelist; fields outside the whitelist are rejected with HTTP 400 and never stored. Four invariant markers (`HTTPS_ENFORCED`, `SCHEMA_STRICT`, `IP_NEVER_STORED`, `NO_BODY_LOGGING`) are required by the CI job `telemetry-worker-privacy`; removing any marker breaks the build.

Run the adversarial smoke suite against the deployed endpoint:

```sh
cd telemetry-worker && ./verify-security.sh
```

The script exercises HTTPS enforcement, method gating, Content-Type gating, size caps, batch caps, schema rejection for every enum violation, and confirms that unknown fields (like `hostname`, `repo`, `ip`) are silently dropped rather than persisted. It exits non-zero on any deviation.

All three are reproducible by a stranger with nothing but a clone of the repo.

## Data lifecycle

- **Local JSONL.** Grows append-only until 10 MB, then rotates to `skill-usage.jsonl.prev` and starts fresh. `.prev` is overwritten on the next rotation. Maximum disk usage is bounded at ~20 MB.
- **Pending markers.** `~/.nanostack/analytics/.pending-$SESSION_ID`. Written at skill start, removed at skill end. If a skill crashes, the marker survives and the next skill run finalizes it as `outcome=unknown`. This is how we detect crash rates honestly without special instrumentation.
- **Remote (Worker D1).** 90 days of raw events. After 90 days, rows are aggregated into daily per-skill counts; `installation_id` and `session_id` are dropped at aggregation. Rate-limit counters in KV expire every 70 seconds.

## Transport security

The Worker is deployed and enforces the contract below. Source: `telemetry-worker/src/index.ts`. Adversarial smoke tests: `telemetry-worker/verify-security.sh` (19 assertions, run against the live endpoint).

### Endpoint

- URL: `https://nanostack-telemetry.remoto.workers.dev/v1/event`
- HTTPS only. Enforced by an explicit check at the top of the Worker handler:

  ```ts
  if (url.protocol !== "https:") {
    return new Response("HTTPS required", { status: 400 });
  }
  ```

  This is a line of code, not a platform default. The CI job `telemetry-worker-privacy` fails the build if the `HTTPS_ENFORCED` marker comment is removed from the Worker source.
- Method: POST with `Content-Type: application/json`. Anything else returns 405 or 415.

### Request (what the client sends)

Headers the client sets explicitly:

- `User-Agent: nanostack-telemetry/<version>` (fixed string, hides local curl version)
- `Content-Type: application/json`

Headers the client never sets: Cookie, Authorization, Referer, X-Forwarded-*, any custom identifier. A CI lint on `bin/telemetry-log.sh` rejects any curl invocation that adds one of these.

Body: a JSON array of one or more events, each conforming exactly to the schema above. Tier-aware stripping happens client-side before the POST:

- Community tier: all declared fields, including `session_id` and `installation_id`.
- Anonymous tier: same fields minus `session_id` and `installation_id`.
- Off tier: the client never issues the request.

What `show-data --remote-preview` prints is byte-identical to what would be POSTed. The preview function and the send function share the same jq filter.

### Client-side policy

- Timeouts: 2s connect, 5s total. Telemetry never blocks a skill.
- Failure mode: fire-and-forget. On any non-2xx or timeout, the event stays in the local queue for the next sync.
- Queue cap: 100 events. Overflow drops the oldest first.
- Rate limit: at most one sync attempt per 5 minutes per installation, tracked via the mtime of `~/.nanostack/analytics/.last-sync-time`.
- Cursor: `~/.nanostack/analytics/.last-sync-line` records the last line successfully acknowledged by the server. Network hiccups do not duplicate events, and aborted syncs do not lose them.

### Server-side policy (the Worker)

- Schema strict. Any field outside `TELEMETRY_FIELDS_V1` returns HTTP 400 and is never stored. Version field (`v`) must equal `1`; other values return 400.
- Payload size cap: 50 KB. Over limit returns 413.
- Batch size cap: 100 events per request. Over limit returns 400.
- Rate limit: 100 requests per minute per client. Key is `sha256(client_ip + daily_rotating_salt)`. Over limit returns 429 with `Retry-After: 60`.
- IP handling: the raw IP from `CF-Connecting-IP` is hashed with a salt that rotates every 24 hours. The hash is used only for the rate-limit counter. Neither the raw IP nor the hash is persisted to D1.
- Worker logging: the source is forbidden from logging request bodies, headers beyond method and status, or any derived content. A CI lint rejects patterns matching `console.log` near the request object.

### D1 schema and retention

- Table `events` stores one row per accepted event. Columns match the declared schema exactly.
- Retention: 90 days of raw events. After 90 days, rows are aggregated into daily per-skill counts. The aggregation drops `installation_id` and `session_id`; only counts survive.
- Access: the Worker reads and writes via a scoped service binding. There is no user-facing SQL interface.

### What network observers still see

When remote sync runs, the TCP connection to `nanostack-telemetry.remoto.workers.dev:443` is visible to the local DNS resolver, the ISP, and any corporate firewall on the path. Inside TLS the payload is encrypted, but the endpoint hostname itself reveals that the source IP uses nanostack. If that observability is unacceptable, stay on tier `off`.

### How to verify this contract holds

- Read the Worker source in `telemetry-worker/src/index.ts`. It is small on purpose.
- Run `telemetry-worker/verify-security.sh` against the live endpoint. It posts adversarial payloads (oversized, wrong schema version, injection attempts, unknown fields) and asserts the expected 4xx responses. Non-zero exit on any failure.
- Inspect the CI jobs `telemetry-privacy` and `telemetry-worker-privacy` on every PR. They fail if the forbidden patterns appear in client or Worker code, or if any of the four Worker invariant markers are removed.

## Enterprise deployment

nanostack is designed so a security team can verify it does not phone home without trusting any runtime logic. Three questions, three answers:

### Does a default install make network calls?

No. Default tier is `off`. On `off`, the client never builds a request and never contacts the Worker. Run this grep on a fresh install:

```sh
grep -rE '(curl|wget|fetch[^a-zA-Z]|nc |http[s]?://[^c])' ~/.claude/skills/nanostack/bin/
```

The only network-capable command in the client paths is the future remote-sync script (lands in a follow-up PR). It is gated on tier being `anonymous` or `community`; on `off` it exits immediately without a network call.

### How do I disable telemetry permanently?

Three independent mechanisms, any of them sufficient. Pick whichever fits your deployment model:

```sh
# Option A: environment variable. Affects the current shell and its children.
export NANOSTACK_NO_TELEMETRY=1

# Option B: user-level file marker. Affects all skill invocations for this user.
touch ~/.nanostack/.telemetry-disabled

# Option C: remove the telemetry helpers entirely. Affects all users of this install.
rm ~/.claude/skills/nanostack/bin/lib/telemetry.sh
rm ~/.claude/skills/nanostack/bin/telemetry-config.sh
```

Option C is the strongest. The skill preambles use defensive sourcing, so removing the helpers leaves the skills functional and makes the absence of telemetry code auditable with `ls`. Verify:

```sh
ls ~/.claude/skills/nanostack/bin/lib/telemetry.sh 2>/dev/null && echo present || echo removed
grep -rE 'nano_telemetry' ~/.claude/skills/nanostack/think/
# Matches appear only inside conditional `[ -f ... ] && source` blocks.
```

### What if the endpoint is blocked at the firewall?

The client treats all network failures as no-ops. A blocked or unreachable Worker does not cause a skill to fail, hang, or retry beyond its local queue. The client's max timeout is 5 seconds; the queue cap is 100 events. If the firewall rejects or drops the connection, events stay on disk until the user manually opts out or the queue rotates.

For regulated environments (air-gapped, data classification, export control) the recommended posture is Option C above, bundled into the deployment script. That install has no code path that can initiate a network request.

## Questions, disagreements, concerns

Open an issue. Please include:

- What you think is wrong (claim vs reality).
- How to reproduce, if applicable.
- What outcome you want.

We take privacy feedback as seriously as we take security bugs.
