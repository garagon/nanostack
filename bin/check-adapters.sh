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

# Known hosts and accepted capability enum values. The capability
# values come from reference/host-adapter-schema.md; bash/write/phase
# all share the same enum. Codex caught the earlier drift on the
# PR 6 first review pass — the docs accepted `detectable`,
# `hooked`, and `host_dependent` while the script was rejecting
# them.
KNOWN_HOSTS="claude cursor codex opencode gemini"
ENFORCEMENT_ENUM="unsupported instructions_only detectable hooked enforced host_dependent"
DISCOVERY_ENUM="native rules_file extension skill_folder instructions_only unsupported unknown host_dependent"
VERIFICATION_METHOD_ENUM="ci manual unknown"
# Supported schema versions. Bump here when the schema doc adds a new
# version and update downstream consumers in the same commit so an
# adapter cannot ship a future-incompatible shape silently.
SCHEMA_VERSION_ENUM="1"

# Adapter names listed in the README. Adapters in this list get the
# strict fail-after-60 policy; an adapter not listed in the README is
# advisory only. Path is anchored at $NANOSTACK_ROOT so the lookup
# does not depend on the caller's cwd (Codex flagged this on the
# PR 6 third review pass — a script invoked from outside the repo
# was producing an empty list and silently downgrading fails to
# warns).
README_LISTED=$(grep -oE '`(claude|cursor|codex|opencode|gemini)`' "$NANOSTACK_ROOT/README.md" 2>/dev/null \
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
FILTER_MATCHED=0

check_adapter() {
  local file="$1"
  local name
  name=$(basename "$file" .json)

  if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    return 0
  fi
  [ -n "$FILTER" ] && FILTER_MATCHED=1

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
  # Full required-field list from reference/host-adapter-schema.md.
  # Codex flagged the truncated check on the PR 6 first review pass:
  # the previous list omitted schema_version, verification,
  # install_target, doctor_checks so an adapter could ship with no
  # verification evidence and still pass.
  for key in host schema_version last_verified verification skill_discovery \
             bash_guard write_guard phase_gate install_target doctor_checks; do
    if ! jq -e --arg k "$key" 'has($k)' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }missing $key"
    fi
  done

  # schema_version must match a known value. Bumping the schema means
  # adding to SCHEMA_VERSION_ENUM in the same commit that updates
  # downstream consumers, so an adapter cannot ship a future-
  # incompatible shape silently. Codex flagged the missing version
  # check on the PR 6 fourth review pass.
  local schema_v
  schema_v=$(jq -r '.schema_version // ""' "$file")
  if [ -z "$schema_v" ]; then
    errors="${errors:+$errors; }schema_version is empty"
  elif ! in_enum "$schema_v" "$SCHEMA_VERSION_ENUM"; then
    errors="${errors:+$errors; }schema_version=$schema_v not in supported set ($SCHEMA_VERSION_ENUM)"
  fi

  # verification must be an object with method + evidence.
  if jq -e '.verification | type == "object"' "$file" >/dev/null 2>&1; then
    local v_method
    v_method=$(jq -r '.verification.method // ""' "$file")
    if [ -z "$v_method" ]; then
      errors="${errors:+$errors; }verification.method is empty"
    elif ! in_enum "$v_method" "$VERIFICATION_METHOD_ENUM"; then
      errors="${errors:+$errors; }verification.method=$v_method not in enum ($VERIFICATION_METHOD_ENUM)"
    fi
    if ! jq -e '.verification.evidence | type == "string" and length > 0' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }verification.evidence is empty or wrong type"
    fi
  elif jq -e 'has("verification")' "$file" >/dev/null 2>&1; then
    # Field exists but is not an object.
    errors="${errors:+$errors; }verification is not an object"
  fi

  # doctor_checks must be a non-empty array of strings. The schema in
  # reference/host-adapter-schema.md says `string[]`; non-string
  # entries pass to downstream doctor/setup code as check names so a
  # numeric or object entry would break runtime lookups. Codex flagged
  # the missing element-type check on the PR 6 third review pass.
  if jq -e 'has("doctor_checks") and (.doctor_checks | type == "array")' "$file" >/dev/null 2>&1; then
    if ! jq -e '.doctor_checks | length > 0' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }doctor_checks is empty"
    elif ! jq -e '.doctor_checks | all(type == "string" and length > 0)' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }doctor_checks must be a non-empty array of strings"
    fi
  elif jq -e 'has("doctor_checks")' "$file" >/dev/null 2>&1; then
    errors="${errors:+$errors; }doctor_checks is not an array"
  fi

  if ! in_enum "$host" "$KNOWN_HOSTS"; then
    errors="${errors:+$errors; }host=$host not in known set ($KNOWN_HOSTS)"
  fi
  # The schema (reference/host-adapter-schema.md) says
  # `adapters/<host>.json` must match the .host field. A mislabeled
  # file (codex.json with host=claude) used to pass and would also
  # satisfy the README missing-file cross-check, so CI could ship a
  # duplicated adapter while claiming the wrong host was verified.
  # Codex flagged this on the PR 6 second review pass.
  if [ "$host" != "$name" ]; then
    errors="${errors:+$errors; }host=$host does not match filename basename=$name"
  fi

  # Empty-string capability values are NOT valid even though the key
  # exists. Codex caught the empty-passes-through hole on the PR 6
  # first review pass: a README-listed adapter with bash_guard=""
  # used to come back OK.
  for field in bash_guard write_guard phase_gate; do
    val=$(eval echo "\$$field")
    if [ -z "$val" ]; then
      errors="${errors:+$errors; }$field is empty"
    elif ! in_enum "$val" "$ENFORCEMENT_ENUM"; then
      errors="${errors:+$errors; }$field=$val not in enum ($ENFORCEMENT_ENUM)"
    fi
  done

  if [ -z "$discovery" ]; then
    # Already reported as missing above when the key was absent. Only
    # flag here if the key exists but the value is empty.
    if jq -e 'has("skill_discovery")' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }skill_discovery is empty"
    fi
  elif ! in_enum "$discovery" "$DISCOVERY_ENUM"; then
    errors="${errors:+$errors; }skill_discovery=$discovery not in enum ($DISCOVERY_ENUM)"
  fi

  local age_days="unknown"
  if [ -n "$last_verified" ]; then
    # Suppress set -e for the parse so we always reach record_result.
    # Codex flagged the silent-exit on the PR 6 first review pass.
    local then_epoch
    set +e
    then_epoch=$(parse_iso_date "$last_verified")
    set -e
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

# When the caller passed a filter and nothing matched, treat that as a
# failure. Otherwise a typo (`check-adapters.sh codxe`) produced an
# empty summary that exited 0, suggesting CI had validated the
# requested adapter when no file matched. Codex flagged this on the
# PR 6 fourth review pass.
if [ -n "$FILTER" ] && [ "$FILTER_MATCHED" = "0" ]; then
  FAIL=$((FAIL + 1))
  RESULTS_TEXT="${RESULTS_TEXT}FAIL  ${FILTER}: no adapters/${FILTER}.json found (filter matched nothing)
"
  RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
    --arg name "$FILTER" \
    '. + [{adapter: $name, status: "fail", age_days: 0, message: "filter matched no adapter file"}]')
fi

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
