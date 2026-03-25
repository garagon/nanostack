#!/usr/bin/env bash
# save-artifact.sh — Save a skill artifact to ~/.nanostack/<phase>/
# Usage: save-artifact.sh <phase> <json-string>
# Example: save-artifact.sh review '{"phase":"review","summary":{"blocking":0}}'
set -e

PHASE="${1:?Usage: save-artifact.sh <phase> <json>}"
JSON="${2:?Missing JSON argument}"
STORE="$HOME/.nanostack/$PHASE"

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
