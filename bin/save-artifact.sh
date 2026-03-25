#!/usr/bin/env bash
# save-artifact.sh — Save a skill artifact to ~/.nanostack/<phase>/
# Usage: save-artifact.sh <phase> <json-string>
# Example: save-artifact.sh review '{"phase":"review","summary":{"blocking":0}}'
# Validates JSON has required fields before saving. Fails on invalid input.
set -e

PHASE="${1:?Usage: save-artifact.sh <phase> <json>}"
JSON="${2:?Missing JSON argument}"
STORE="$HOME/.nanostack/$PHASE"
VALID_PHASES="think plan review qa security ship"

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

# Inject timestamp and project path if not present
ENRICHED=$(echo "$JSON" | jq \
  --arg ts "$TIMESTAMP" \
  --arg proj "$(pwd)" \
  --arg branch "$(git branch --show-current 2>/dev/null || echo 'unknown')" \
  '. + {timestamp: ($ts), project: ($proj), branch: ($branch)}')

echo "$ENRICHED" | jq '.' > "$FILENAME"
echo "$FILENAME"
