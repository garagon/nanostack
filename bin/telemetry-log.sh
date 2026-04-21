#!/usr/bin/env bash
# telemetry-log.sh — async sender for opt-in telemetry.
#
# Reads ~/.nanostack/analytics/skill-usage.jsonl, strips tier-specific
# fields, POSTs a batch to the Worker, advances the cursor on 2xx with
# inserted > 0. Fire-and-forget: never exits non-zero to the caller, never
# blocks longer than its max-time curl budget, never retries synchronously.
#
# Invoked as a background process by nano_telemetry_finalize in
# bin/lib/telemetry.sh, or manually by the user.
#
# Kill switches (any one is sufficient to prevent all network activity):
#   NANOSTACK_NO_TELEMETRY=1 in the environment
#   ~/.nanostack/.telemetry-disabled file present
#   bin/telemetry-log.sh removed from the install
#
# Privacy contract (enforced by CI lint):
#   - Endpoint URL is hardcoded https://. Not configurable.
#   - User-Agent is fixed string. curl's default UA is never sent.
#   - Cookies, Authorization, Referer, -v / --verbose are forbidden.
#   - Max batch = 100 events. Max payload = 50 KB. Cursor advances only on 2xx.

set -uo pipefail

# ─── Paths (user-scoped, NOT project-scoped) ──────────────────────────
# Resolved first so the marker-file kill switch below can use the override.
NANO_TEL_HOME="${NANO_TEL_HOME:-$HOME/.nanostack}"

# ─── Kill switches ────────────────────────────────────────────────────
[ -n "${NANOSTACK_NO_TELEMETRY:-}" ] && exit 0
[ -f "$NANO_TEL_HOME/.telemetry-disabled" ] && exit 0

# ─── Dependencies ─────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v sed >/dev/null 2>&1 || exit 0

# ─── Remaining paths ──────────────────────────────────────────────────
NANO_TEL_CONFIG="$NANO_TEL_HOME/user-config.json"
NANO_TEL_INSTALL_ID_FILE="$NANO_TEL_HOME/installation-id"
NANO_TEL_ANALYTICS_DIR="$NANO_TEL_HOME/analytics"
NANO_TEL_JSONL="$NANO_TEL_ANALYTICS_DIR/skill-usage.jsonl"
CURSOR_FILE="$NANO_TEL_ANALYTICS_DIR/.last-sync-line"
RATE_FILE="$NANO_TEL_ANALYTICS_DIR/.last-sync-time"

# Endpoint is hardcoded. Not configurable by env or flag; an attacker who
# flips an env var cannot redirect telemetry to a collector they control.
NANO_TEL_ENDPOINT="https://nanostack-telemetry.remoto.workers.dev/v1/event"
NANO_TEL_UA="nanostack-telemetry/0.5.0"
NANO_TEL_MAX_BATCH=100
NANO_TEL_MAX_PAYLOAD_BYTES=50000

# ─── Pre-checks ────────────────────────────────────────────────────────
# No JSONL → nothing to sync.
[ -f "$NANO_TEL_JSONL" ] || exit 0

# Read tier. Off → exit silently.
if [ -f "$NANO_TEL_CONFIG" ]; then
  TIER=$(jq -r '.telemetry // "off"' "$NANO_TEL_CONFIG" 2>/dev/null)
else
  TIER="off"
fi
case "$TIER" in
  anonymous|community) ;;
  *) exit 0 ;;
esac

# Rate limit: at most one sync per 5 minutes per install. The mtime of
# RATE_FILE carries the last attempted sync time. `find -mmin +5` returns
# the file iff older than 5 min; no output means we are still inside the
# window and must defer.
if [ -f "$RATE_FILE" ]; then
  STALE=$(find "$RATE_FILE" -mmin +5 -print 2>/dev/null || true)
  [ -z "$STALE" ] && exit 0
fi

# ─── Cursor ────────────────────────────────────────────────────────────
CURSOR=0
if [ -f "$CURSOR_FILE" ]; then
  CURSOR=$(cat "$CURSOR_FILE" 2>/dev/null | tr -d ' \n\r\t')
  case "$CURSOR" in *[!0-9]*) CURSOR=0 ;; esac
fi

TOTAL_LINES=$(wc -l < "$NANO_TEL_JSONL" 2>/dev/null | tr -d ' ')
if [ -z "$TOTAL_LINES" ] || [ "$CURSOR" -gt "$TOTAL_LINES" ] 2>/dev/null; then
  CURSOR=0
fi
[ "${CURSOR:-0}" -ge "${TOTAL_LINES:-0}" ] 2>/dev/null && exit 0

SKIP=$(( CURSOR + 1 ))
UNSENT=$(tail -n "+$SKIP" "$NANO_TEL_JSONL" 2>/dev/null || true)
[ -z "$UNSENT" ] && exit 0

# ─── Build batch (tier-aware stripping) ───────────────────────────────
BATCH="["
FIRST=1
COUNT=0

while IFS= read -r LINE; do
  [ -z "$LINE" ] && continue
  # Skip lines that are not JSON objects.
  case "$LINE" in "{"*"}") ;; *) continue ;; esac

  # Anonymous tier: drop session_id and installation_id. Community: keep all.
  # The filter is byte-identical to what `show-data --remote-preview` uses,
  # enforcing the promise that preview == send.
  if [ "$TIER" = "anonymous" ]; then
    CLEAN=$(printf '%s' "$LINE" | jq -c 'del(.session_id, .installation_id)' 2>/dev/null)
  else
    CLEAN=$(printf '%s' "$LINE" | jq -c '.' 2>/dev/null)
  fi
  [ -z "$CLEAN" ] && continue

  if [ "$FIRST" = "1" ]; then
    FIRST=0
    BATCH="$BATCH$CLEAN"
  else
    BATCH="$BATCH,$CLEAN"
  fi
  COUNT=$(( COUNT + 1 ))
  [ "$COUNT" -ge "$NANO_TEL_MAX_BATCH" ] && break
done <<< "$UNSENT"

BATCH="$BATCH]"
[ "$COUNT" -eq 0 ] && exit 0

# Final size gate. Worker caps at 50 KB; drop the attempt if the local
# batch would overshoot after stripping, rather than truncate mid-event.
BATCH_BYTES=${#BATCH}
if [ "$BATCH_BYTES" -gt "$NANO_TEL_MAX_PAYLOAD_BYTES" ]; then
  exit 0
fi

# ─── POST (curl invocation is the only network call in nanostack) ─────
# The curl flag list is fixed and audited by CI:
#   --silent --show-error: no prompt spam, stderr on hard error only
#   --user-agent: fixed string. CI rejects if missing or variable.
#   --max-time / --connect-timeout: never blocks the caller > 5s
#   --request POST: explicit
#   --header Content-Type: application/json: the only content header sent
#   --data-binary @-: body from stdin, no shell interpolation into argv
# Forbidden flags (CI lint): --cookie, --cookie-jar, --user, --header Cookie,
#   --header Authorization, --header Referer, --location, -v, --verbose,
#   --dump-header, --trace, http:// URLs.
RESP_FILE=$(mktemp "/tmp/nano-tel-send.XXXXXX" 2>/dev/null) || exit 0
HTTP_CODE=$(printf '%s' "$BATCH" | curl \
  --silent --show-error \
  --user-agent "$NANO_TEL_UA" \
  --max-time 5 \
  --connect-timeout 2 \
  --request POST \
  --header "Content-Type: application/json" \
  --data-binary @- \
  --output "$RESP_FILE" \
  --write-out '%{http_code}' \
  "$NANO_TEL_ENDPOINT" 2>/dev/null || echo "000")

# ─── Advance cursor on 2xx with inserted > 0 ──────────────────────────
case "$HTTP_CODE" in
  2*)
    INSERTED=$(jq -r '.inserted // 0' "$RESP_FILE" 2>/dev/null | head -1)
    case "$INSERTED" in *[!0-9]*|'') INSERTED=0 ;; esac
    if [ "$INSERTED" -gt 0 ] 2>/dev/null; then
      NEW_CURSOR=$(( CURSOR + COUNT ))
      printf '%s' "$NEW_CURSOR" > "$CURSOR_FILE" 2>/dev/null || true
      chmod 600 "$CURSOR_FILE" 2>/dev/null || true
    fi
    ;;
esac

rm -f "$RESP_FILE" 2>/dev/null || true

# Always update the rate-limit marker, even on failure, so a failing endpoint
# does not spin the sender every invocation.
touch "$RATE_FILE" 2>/dev/null || true

exit 0
