#!/usr/bin/env bash
# save-artifact.sh — Save a skill artifact to .nanostack/<phase>/
# Usage: save-artifact.sh <phase> <json-string>
# Example: save-artifact.sh review '{"phase":"review","summary":{"blocking":0}}'
# Validates JSON has required fields before saving. Fails on invalid input.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

PHASE="${1:?Usage: save-artifact.sh <phase> <json>}"
JSON="${2:?Missing JSON argument}"
STORE="$NANOSTACK_STORE/$PHASE"
CORE_PHASES="think plan review qa security ship"

# Load custom phases from config if exists
CUSTOM_PHASES=""
CONFIG="$NANOSTACK_STORE/config.json"
if [ -f "$CONFIG" ]; then
  CUSTOM_PHASES=$(jq -r '.custom_phases // [] | join(" ")' "$CONFIG" 2>/dev/null || echo "")
fi

VALID_PHASES="$CORE_PHASES $CUSTOM_PHASES"

# Validate phase name
case " $VALID_PHASES " in
  *" $PHASE "*) ;;
  *) echo "error: invalid phase '$PHASE'. Must be one of: $VALID_PHASES" >&2; exit 1 ;;
esac

# Validate JSON is parseable
if ! echo "$JSON" | jq '.' >/dev/null 2>&1; then
  echo "error: invalid JSON input" >&2
  exit 1
fi

# Validate required fields
MISSING=""
if ! echo "$JSON" | jq -e '.phase' >/dev/null 2>&1; then
  MISSING="phase"
fi
if ! echo "$JSON" | jq -e '.summary' >/dev/null 2>&1; then
  MISSING="${MISSING:+$MISSING, }summary"
fi
if [ -n "$MISSING" ]; then
  echo "error: artifact missing required fields: $MISSING" >&2
  exit 1
fi

# Validate phase field matches argument
ARTIFACT_PHASE=$(echo "$JSON" | jq -r '.phase')
if [ "$ARTIFACT_PHASE" != "$PHASE" ]; then
  echo "error: phase argument '$PHASE' does not match artifact phase '$ARTIFACT_PHASE'" >&2
  exit 1
fi

mkdir -p "$STORE"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FILENAME="$STORE/$(date -u +"%Y%m%d-%H%M%S").json"

# ── Secret scanning: redact credentials before persisting ──
# Patterns: Stripe, Anthropic, AWS, GitHub, Slack, OpenAI
SECRET_PATTERNS='sk_live_[a-zA-Z0-9]{20,}|sk_test_[a-zA-Z0-9]{20,}|sk-ant-[a-zA-Z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|xoxb-[0-9a-zA-Z-]{20,}|xoxp-[0-9a-zA-Z-]{20,}|sk-[a-zA-Z0-9]{48,}'
SECRETS_FOUND=$(echo "$JSON" | grep -oiE "$SECRET_PATTERNS" 2>/dev/null | sort -u)
if [ -n "$SECRETS_FOUND" ]; then
  echo "warning: artifact contains potential secrets — redacting before save" >&2
  while IFS= read -r secret; do
    [ -z "$secret" ] && continue
    PREFIX=$(echo "$secret" | cut -c1-8)
    JSON=$(echo "$JSON" | sed "s|$secret|${PREFIX}***REDACTED***|g")
  done <<< "$SECRETS_FOUND"
fi

# ── Truncate findings if too many ──
MAX_FINDINGS="${NANOSTACK_MAX_FINDINGS:-50}"
FINDING_COUNT=$(echo "$JSON" | jq '.findings | length' 2>/dev/null || echo 0)
if [ "$FINDING_COUNT" -gt "$MAX_FINDINGS" ]; then
  echo "warning: truncating findings from $FINDING_COUNT to $MAX_FINDINGS" >&2
  JSON=$(echo "$JSON" | jq --argjson max "$MAX_FINDINGS" --argjson total "$FINDING_COUNT" \
    '.findings = (.findings[:$max] + [{"id":"TRUNCATED","severity":"info","description":"\($total) total findings. Showing first \($max)."}]) | .truncated = true')
fi

# Inject timestamp and project path if not present
ENRICHED=$(echo "$JSON" | jq \
  --arg ts "$TIMESTAMP" \
  --arg proj "$(pwd)" \
  --arg branch "$(git branch --show-current 2>/dev/null || echo 'unknown')" \
  '. + {timestamp: ($ts), project: ($proj), branch: ($branch)}')

# ── Integrity checksum ──
CHECKSUM=$(echo "$ENRICHED" | jq -Sc '.' | shasum -a 256 | cut -d' ' -f1)
ENRICHED=$(echo "$ENRICHED" | jq --arg cs "$CHECKSUM" '. + {integrity: $cs}')

echo "$ENRICHED" | jq '.' > "$FILENAME"
echo "$FILENAME"
