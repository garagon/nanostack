#!/usr/bin/env bash
# verify-security.sh — adversarial smoke tests against a deployed Worker.
# Run after `wrangler deploy` to prove the security contract holds end to end.
# Exits non-zero on any assertion failure.
#
# Usage:
#   ./verify-security.sh [endpoint-url]
# Default endpoint: https://nanostack-telemetry.remoto.workers.dev
set -u

ENDPOINT="${1:-https://nanostack-telemetry.remoto.workers.dev}"
EVENT_URL="$ENDPOINT/v1/event"

PASS=0
FAIL=0

_say_ok()   { printf "  \033[32mOK\033[0m    %s\n" "$1"; PASS=$((PASS+1)); }
_say_fail() { printf "  \033[31mFAIL\033[0m  %s (got %s, expected %s)\n" "$1" "$2" "$3"; FAIL=$((FAIL+1)); }

# assert_status <description> <expected-code> <curl-args...>
assert_status() {
  local desc="$1" expected="$2"; shift 2
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || echo "000")
  if [ "$code" = "$expected" ]; then
    _say_ok "$desc"
  else
    _say_fail "$desc" "$code" "$expected"
  fi
}

# assert_json_field <description> <field> <expected> <curl-args...>
assert_json_field() {
  local desc="$1" field="$2" expected="$3"; shift 3
  local body
  body=$(curl -sS --max-time 5 "$@" 2>/dev/null || echo "{}")
  local got
  got=$(printf '%s' "$body" | jq -r ".$field // \"null\"" 2>/dev/null || echo "parse-error")
  if [ "$got" = "$expected" ]; then
    _say_ok "$desc"
  else
    _say_fail "$desc" "$got" "$expected"
  fi
}

printf "Testing %s\n\n" "$ENDPOINT"

# ─── Liveness (sanity check that the Worker is up) ─────────────
printf "Liveness:\n"
assert_status "GET / → 200" 200 "$ENDPOINT/"

# ─── HTTPS enforcement ─────────────────────────────────────────
printf "\nHTTPS enforcement:\n"
# curl follows 301/302 by default — we do NOT pass -L, so an HTTP 400 response
# from the Worker surfaces directly without any redirect interference.
HTTP_URL=$(printf '%s' "$EVENT_URL" | sed 's|^https:|http:|')
assert_status "POST http:// → 400 (HTTPS required)" 400 \
  -X POST -H "Content-Type: application/json" -d '{}' "$HTTP_URL"

# ─── Method gate ────────────────────────────────────────────────
printf "\nMethod gate:\n"
assert_status "PUT /v1/event → 405" 405 -X PUT -H "Content-Type: application/json" -d '{}' "$EVENT_URL"
assert_status "DELETE /v1/event → 405" 405 -X DELETE "$EVENT_URL"
assert_status "GET /v1/event → 405" 405 "$EVENT_URL"

# ─── Content-Type gate ──────────────────────────────────────────
printf "\nContent-Type gate:\n"
assert_status "POST without Content-Type → 415" 415 \
  -X POST --data-binary 'not json' "$EVENT_URL"
assert_status "POST Content-Type: text/plain → 415" 415 \
  -X POST -H "Content-Type: text/plain" --data-binary 'not json' "$EVENT_URL"

# ─── Routing ────────────────────────────────────────────────────
printf "\nRouting:\n"
assert_status "POST /v1/other → 404" 404 \
  -X POST -H "Content-Type: application/json" -d '{}' "$ENDPOINT/v1/other"

# ─── Malformed JSON ─────────────────────────────────────────────
printf "\nMalformed JSON:\n"
assert_status "POST invalid JSON → 400" 400 \
  -X POST -H "Content-Type: application/json" --data-binary 'not{json' "$EVENT_URL"

# ─── Oversized payload (51KB) ───────────────────────────────────
printf "\nSize limits:\n"
BIG=$(printf '{"v":1,"ts":"2026-04-21T12:00:00Z","skill":"test","outcome":"success","pad":"%.0s' "$(seq 1 1)")
BIG_PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"v":1,"ts":"2026-04-21T12:00:00Z","skill":"test","outcome":"success","pad":"x"*51000}))' 2>/dev/null || printf '{"pad":"%*s"}' 51000 '')
assert_status "POST 51KB payload → 413" 413 \
  -X POST -H "Content-Type: application/json" --data-binary "$BIG_PAYLOAD" "$EVENT_URL"

# Oversized batch (101 events)
BATCH_101=$(python3 -c '
import json
e = {"v":1,"ts":"2026-04-21T12:00:00Z","skill":"test","outcome":"success"}
print(json.dumps([e]*101))
' 2>/dev/null || echo '[]')
assert_status "POST 101-event batch → 400" 400 \
  -X POST -H "Content-Type: application/json" --data-binary "$BATCH_101" "$EVENT_URL"

# ─── Schema rejection (all should be dropped, response is 400 when ALL rejected) ─
printf "\nSchema validation (all-rejected returns 400):\n"
assert_status "wrong version v=2 → 400 (all rejected)" 400 \
  -X POST -H "Content-Type: application/json" \
  -d '{"v":2,"ts":"2026-04-21T12:00:00Z","skill":"test","outcome":"success"}' "$EVENT_URL"

assert_status "os outside enum → 400" 400 \
  -X POST -H "Content-Type: application/json" \
  -d '{"v":1,"ts":"2026-04-21T12:00:00Z","skill":"test","outcome":"success","os":"windows"}' "$EVENT_URL"

assert_status "outcome outside enum → 400" 400 \
  -X POST -H "Content-Type: application/json" \
  -d '{"v":1,"ts":"2026-04-21T12:00:00Z","skill":"test","outcome":"victorious"}' "$EVENT_URL"

assert_status "injection-like outcome → 400" 400 \
  -X POST -H "Content-Type: application/json" \
  -d "{\"v\":1,\"ts\":\"2026-04-21T12:00:00Z\",\"skill\":\"test\",\"outcome\":\"success'; DROP TABLE events; --\"}" "$EVENT_URL"

assert_status "malformed ts → 400" 400 \
  -X POST -H "Content-Type: application/json" \
  -d '{"v":1,"ts":"not-a-date","skill":"test","outcome":"success"}' "$EVENT_URL"

assert_status "negative duration → 400" 400 \
  -X POST -H "Content-Type: application/json" \
  -d '{"v":1,"ts":"2026-04-21T12:00:00Z","skill":"test","outcome":"success","duration_s":-5}' "$EVENT_URL"

# ─── Valid payload accepted ─────────────────────────────────────
printf "\nHappy path:\n"
VALID='{"v":1,"ts":"2026-04-21T12:00:00Z","skill":"verify_test","outcome":"success","os":"darwin","arch":"arm64","nanostack_version":"0.5.0-test","duration_s":1}'
assert_json_field "valid event returns inserted:1" "inserted" "1" \
  -X POST -H "Content-Type: application/json" -d "$VALID" "$EVENT_URL"

# Unknown fields are dropped, event still accepted
VALID_WITH_JUNK='{"v":1,"ts":"2026-04-21T12:00:00Z","skill":"verify_test","outcome":"success","hostname":"pwned","repo":"secret","ip":"1.2.3.4"}'
assert_json_field "unknown fields silently dropped (hostname/repo/ip) → inserted:1" "inserted" "1" \
  -X POST -H "Content-Type: application/json" -d "$VALID_WITH_JUNK" "$EVENT_URL"

# ─── Summary ────────────────────────────────────────────────────
printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
