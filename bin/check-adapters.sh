#!/usr/bin/env bash
# check-adapters.sh — Validate adapters/<host>.json files.
#
# PR 6 of the 2026-05-10 architecture audit. Adapters declare what a
# given host (claude, codex, cursor, opencode, gemini, ...) actually
# enforces for the Bash guard, write guard, and phase gate. This
# script validates schema + capability enum membership + last_verified
# freshness and surfaces drift before it reaches a release.
#
# Usage:
#   bin/check-adapters.sh                Validate every adapters/*.json.
#   bin/check-adapters.sh <host>         Validate one adapter.
#   bin/check-adapters.sh --json         Machine-readable summary.
#
# Freshness policy:
#   - warn after 30 days
#   - fail after 60 days for README-listed adapters
#   - manual override: NANOSTACK_ALLOW_STALE_ADAPTERS=1 downgrades the
#     fail to a warning. Not for CI; intended for `bin/check-adapters.sh`
#     when a maintainer is explicitly re-running on an old branch.
#
# Exit code:
#   0  all adapters validate within the freshness window
#   1  any adapter is malformed, missing a required key, has a value
#      outside the enum, has unparseable last_verified, or is stale
#      beyond the README-fail threshold
set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NANOSTACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER_DIR="$NANOSTACK_ROOT/adapters"

WARN_DAYS=30
FAIL_DAYS=60

JSON_OUT=false
FILTER=""
for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUT=true ;;
    -h|--help)
      sed -n '/^# /,/^$/p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) FILTER="$arg" ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

if [ ! -d "$ADAPTER_DIR" ]; then
  echo "ERROR: $ADAPTER_DIR does not exist" >&2
  exit 1
fi

# Known hosts and accepted capability enum values.
KNOWN_HOSTS="claude cursor codex opencode gemini"
ENFORCEMENT_ENUM="enforced reported instructions_only unsupported unknown"
DISCOVERY_ENUM="native rules_file extension skill_folder instructions_only unsupported unknown"

# Adapter names listed in the README. Adapters in this list get the
# strict fail-after-60 policy; an adapter not listed in the README is
# advisory only.
README_LISTED=$(grep -oE '`(claude|cursor|codex|opencode|gemini)`' README.md 2>/dev/null \
  | tr -d '`' | sort -u | tr '\n' ' ')

NOW_EPOCH=$(date -u +%s)

in_enum() {
  local val="$1" enum="$2"
  case " $enum " in
    *" $val "*) return 0 ;;
  esac
  return 1
}

parse_iso_date() {
  local d="$1"
  if command -v gdate >/dev/null 2>&1; then
    gdate -u -d "$d" +%s 2>/dev/null
  else
    date -u -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null \
      || date -u -d "$d" +%s 2>/dev/null
  fi
}

FAIL=0
WARN=0
RESULTS_JSON="[]"
RESULTS_TEXT=""

check_adapter() {
  local file="$1"
  local name
  name=$(basename "$file" .json)

  if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    return 0
  fi

  local host last_verified bash_guard write_guard phase_gate discovery method
  if ! jq -e '.' "$file" >/dev/null 2>&1; then
    record_result "$name" "fail" "invalid JSON" "" 0
    return 0
  fi

  host=$(jq -r '.host // ""' "$file")
  last_verified=$(jq -r '.last_verified // ""' "$file")
  bash_guard=$(jq -r '.bash_guard // ""' "$file")
  write_guard=$(jq -r '.write_guard // ""' "$file")
  phase_gate=$(jq -r '.phase_gate // ""' "$file")
  discovery=$(jq -r '.skill_discovery // ""' "$file")
  method=$(jq -r '.verification.method // ""' "$file")

  local errors=""
  for key in host last_verified bash_guard write_guard phase_gate skill_discovery; do
    if ! jq -e --arg k "$key" 'has($k)' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }missing $key"
    fi
  done

  if ! in_enum "$host" "$KNOWN_HOSTS"; then
    errors="${errors:+$errors; }host=$host not in known set ($KNOWN_HOSTS)"
  fi

  for field in bash_guard write_guard phase_gate; do
    val=$(eval echo "\$$field")
    if [ -n "$val" ] && ! in_enum "$val" "$ENFORCEMENT_ENUM"; then
      errors="${errors:+$errors; }$field=$val not in enum ($ENFORCEMENT_ENUM)"
    fi
  done

  if [ -n "$discovery" ] && ! in_enum "$discovery" "$DISCOVERY_ENUM"; then
    errors="${errors:+$errors; }skill_discovery=$discovery not in enum ($DISCOVERY_ENUM)"
  fi

  local age_days="unknown"
  if [ -n "$last_verified" ]; then
    local then_epoch
    then_epoch=$(parse_iso_date "$last_verified")
    if [ -z "$then_epoch" ]; then
      errors="${errors:+$errors; }last_verified=$last_verified does not parse as a date"
    else
      age_days=$(( (NOW_EPOCH - then_epoch) / 86400 ))
    fi
  else
    errors="${errors:+$errors; }last_verified is empty"
  fi

  local status="ok"
  if [ -n "$errors" ]; then
    status="fail"
  elif [ "$age_days" != "unknown" ]; then
    if [ "$age_days" -gt "$FAIL_DAYS" ]; then
      case " $README_LISTED " in
        *" $host "*)
          if [ "${NANOSTACK_ALLOW_STALE_ADAPTERS:-0}" = "1" ]; then
            status="warn"
            errors="last_verified is $age_days days old (>$FAIL_DAYS); override active"
          else
            status="fail"
            errors="last_verified is $age_days days old (>$FAIL_DAYS) and $host is README-listed"
          fi
          ;;
        *)
          status="warn"
          errors="last_verified is $age_days days old (>$FAIL_DAYS) but $host is not README-listed"
          ;;
      esac
    elif [ "$age_days" -gt "$WARN_DAYS" ]; then
      status="warn"
      errors="last_verified is $age_days days old (>$WARN_DAYS)"
    fi
  fi

  record_result "$name" "$status" "$errors" "$age_days" "$([ "$age_days" = "unknown" ] && echo 0 || echo "$age_days")"
}

record_result() {
  local name="$1" status="$2" message="$3" age_days="$4" age_int="$5"
  case "$status" in
    fail) FAIL=$((FAIL + 1)) ;;
    warn) WARN=$((WARN + 1)) ;;
  esac
  RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
    --arg name "$name" \
    --arg status "$status" \
    --arg message "$message" \
    --argjson age "${age_int:-0}" \
    '. + [{adapter: $name, status: $status, age_days: $age, message: ($message // "")}]')
  if [ "$status" = "ok" ]; then
    RESULTS_TEXT="${RESULTS_TEXT}OK    $name (age $age_days days)
"
  else
    local label
    label=$(echo "$status" | tr '[:lower:]' '[:upper:]')
    RESULTS_TEXT="${RESULTS_TEXT}${label}  $name: $message
"
  fi
}

for f in "$ADAPTER_DIR"/*.json; do
  [ -f "$f" ] || continue
  check_adapter "$f"
done

# Cross-check: every README-listed adapter must have a JSON file.
for host in $README_LISTED; do
  [ -z "$host" ] && continue
  if [ ! -f "$ADAPTER_DIR/${host}.json" ]; then
    FAIL=$((FAIL + 1))
    RESULTS_TEXT="${RESULTS_TEXT}FAIL  ${host}: listed in README but no adapters/${host}.json
"
    RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
      --arg name "$host" \
      '. + [{adapter: $name, status: "fail", age_days: 0, message: "listed in README but no JSON file"}]')
  fi
done

if $JSON_OUT; then
  jq -n --argjson results "$RESULTS_JSON" --argjson fail "$FAIL" --argjson warn "$WARN" \
    '{adapters: $results, summary: {fail: $fail, warn: $warn}}'
else
  printf '%s' "$RESULTS_TEXT"
  echo "---"
  echo "Summary: $FAIL failed, $WARN warned"
fi

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
