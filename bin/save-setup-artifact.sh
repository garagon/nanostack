#!/usr/bin/env bash
# save-setup-artifact.sh — Save the /nano-run setup artifact.
#
# Why a separate script: setup runs before any session exists and
# before the canonical sprint phase machinery is wired. save-artifact.sh
# auto-calls session.sh phase-complete and validates against the
# sprint phase schema; setup is not a sprint phase. Keeping the two
# writers separate avoids hacking sprint mechanics for first-run.
#
# Schema source of truth: reference/artifact-schema.md, "/nano-run
# (setup)" section.
#
# Usage:
#   save-setup-artifact.sh <json>                Validate and save
#   save-setup-artifact.sh --validate <json>     Validate only, do not write
#
# Output paths (project-local store via store-path.sh):
#   $NANOSTACK_STORE/setup/<UTC-timestamp>.json     versioned write
#   $NANOSTACK_STORE/setup/latest.json              copy (no symlink, portability)
#
# Exit codes:
#   0  saved (or validated when --validate)
#   1  invalid JSON or missing required field
#   2  io error (could not write store)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
[ -f "$SCRIPT_DIR/lib/preflight.sh" ] && { source "$SCRIPT_DIR/lib/preflight.sh"; nanostack_require jq; }

VALIDATE_ONLY=0
if [ "${1:-}" = "--validate" ]; then
  VALIDATE_ONLY=1
  shift
fi

JSON="${1:-}"
if [ -z "$JSON" ]; then
  echo "Usage: save-setup-artifact.sh [--validate] <json>" >&2
  exit 1
fi

# ─── Parse + validate ──────────────────────────────────────────────────
# Required fields per reference/artifact-schema.md /nano-run (setup).
# Each line is one jq path. Missing or empty values fail closed; the
# spec calls report_only "honest about not having mutated" so the
# script must not accept a payload that lies about what happened.

REQUIRED_PATHS='
.phase
.summary.status
.summary.profile
.summary.host
.summary.run_mode
.summary.project_mode
.summary.capabilities.bash_guard
.summary.capabilities.write_guard
.summary.capabilities.phase_gate
.summary.configuration.config_json
.summary.configuration.stack_json
.summary.configuration.project_settings
.summary.configuration.gitignore
.summary.recommended_first_run.kind
.summary.recommended_first_run.command
.context_checkpoint.summary
'

if ! echo "$JSON" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: input is not valid JSON" >&2
  exit 1
fi

PHASE=$(echo "$JSON" | jq -r '.phase // ""')
if [ "$PHASE" != "setup" ]; then
  echo "ERROR: phase must be 'setup', got '$PHASE'" >&2
  exit 1
fi

# Loop the required paths. jq's `has` only walks one level, so we
# evaluate each path with a small filter and fail when the result
# is null OR empty string (both count as missing).
fail=0
while IFS= read -r path; do
  [ -z "$path" ] && continue
  value=$(echo "$JSON" | jq -r "$path // empty")
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "ERROR: required field missing or empty: $path" >&2
    fail=1
  fi
done <<EOF
$REQUIRED_PATHS
EOF

if [ "$fail" -ne 0 ]; then
  exit 1
fi

# Enum validation. Adapter values map to the L0-L3 honesty rule.
# Five legal values; any other shape is a bug, not a new value.
for cap in bash_guard write_guard phase_gate; do
  v=$(echo "$JSON" | jq -r ".summary.capabilities.$cap // \"\"")
  case "$v" in
    enforced|reported|instructions_only|unsupported|unknown) ;;
    *)
      echo "ERROR: summary.capabilities.$cap must be one of enforced|reported|instructions_only|unsupported|unknown, got '$v'" >&2
      exit 1
      ;;
  esac
done

# Status enum.
status=$(echo "$JSON" | jq -r '.summary.status')
case "$status" in
  ready|needs_repair|report_only|partial|blocked) ;;
  *)
    echo "ERROR: summary.status must be one of ready|needs_repair|report_only|partial|blocked, got '$status'" >&2
    exit 1
    ;;
esac

# report_only contract: configuration values must reflect that
# nothing was written. A status=report_only payload that claims
# files were created/updated is a lie and the writer rejects it.
if [ "$status" = "report_only" ]; then
  for cfg in config_json stack_json project_settings gitignore; do
    v=$(echo "$JSON" | jq -r ".summary.configuration.$cfg")
    case "$v" in
      created|updated)
        echo "ERROR: report_only artifact cannot claim configuration.$cfg='$v' — must be exists, skipped_report_only, not_applicable, or error" >&2
        exit 1
        ;;
    esac
  done
fi

if [ "$VALIDATE_ONLY" -eq 1 ]; then
  echo "ok"
  exit 0
fi

# ─── Write ─────────────────────────────────────────────────────────────

OUT_DIR="$NANOSTACK_STORE/setup"
mkdir -p "$OUT_DIR" || { echo "ERROR: cannot create $OUT_DIR" >&2; exit 2; }

TS=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
TS_FILE="$OUT_DIR/${TS}.json"
LATEST="$OUT_DIR/latest.json"

# Inject timestamp + project at write time, the way save-artifact.sh
# does for sprint phases. The skill writer can omit these.
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PROJECT="$(pwd)"
BRANCH=$(git branch --show-current 2>/dev/null || echo "")

ENRICHED=$(echo "$JSON" | jq \
  --arg ts "$NOW_ISO" \
  --arg project "$PROJECT" \
  --arg branch "$BRANCH" \
  '. + {
     timestamp: (.timestamp // $ts),
     project:   (.project   // $project),
     branch:    (.branch    // (if $branch == "" then null else $branch end)),
     schema_version: (.schema_version // "1")
  }')

if ! printf '%s\n' "$ENRICHED" > "$TS_FILE"; then
  echo "ERROR: cannot write $TS_FILE" >&2
  exit 2
fi

# latest.json is a copy, not a symlink. Some Windows / WSL setups
# refuse symlinks across drives; the test suite runs on those too.
if ! cp "$TS_FILE" "$LATEST"; then
  echo "ERROR: cannot copy $TS_FILE to $LATEST" >&2
  exit 2
fi

echo "$TS_FILE"
