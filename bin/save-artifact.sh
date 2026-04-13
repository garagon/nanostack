#!/usr/bin/env bash
# save-artifact.sh — Save a skill artifact to .nanostack/<phase>/
# Usage:
#   save-artifact.sh <phase> <json-string>              (full mode)
#   save-artifact.sh --from-session <phase> <summary>   (simplified mode)
#
# Full mode: pass complete JSON with phase, summary, context_checkpoint.
# Session mode: reads phase from session, builds JSON from git state + summary string.
#   Auto-calls session.sh phase-complete after saving.
#
# Validates JSON has required fields before saving. Fails on invalid input.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
source "$SCRIPT_DIR/lib/audit.sh"

# ─── Session mode: build JSON from git state + summary ──────
if [ "${1:-}" = "--from-session" ]; then
  PHASE="${2:?Usage: save-artifact.sh --from-session <phase> <summary>}"
  SUMMARY_TEXT="${3:?Missing summary argument}"

  PROJECT="$(pwd)"
  BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

  # Build context checkpoint from git state
  CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null | head -20 | jq -R . | jq -s . 2>/dev/null || echo "[]")
  STAGED_FILES=$(git diff --cached --name-only 2>/dev/null | head -20 | jq -R . | jq -s . 2>/dev/null || echo "[]")
  RECENT_COMMITS=$(git log --oneline -5 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")

  JSON=$(jq -n \
    --arg phase "$PHASE" \
    --arg summary "$SUMMARY_TEXT" \
    --arg project "$PROJECT" \
    --arg branch "$BRANCH" \
    --argjson changed "$CHANGED_FILES" \
    --argjson staged "$STAGED_FILES" \
    --argjson commits "$RECENT_COMMITS" \
    '{
      phase: $phase,
      summary: $summary,
      context_checkpoint: {
        summary: $summary,
        key_files: ($changed + $staged | unique),
        recent_commits: $commits,
        decisions_made: [],
        open_questions: []
      }
    }')

  # Run the standard save logic below
  shift 3 || true
  set -- "$PHASE" "$JSON"
fi

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
audit_log "artifact_saved" "$PHASE" "$(basename "$FILENAME")"
echo "$FILENAME"

# ─── Auto-complete phase in session ──────────────────────────
# Always update session when an active session exists, regardless of save mode.
SESSION_SH="$SCRIPT_DIR/session.sh"
if [ -x "$SESSION_SH" ] && [ -f "$NANOSTACK_STORE/session.json" ]; then
  "$SESSION_SH" phase-start "$PHASE" >/dev/null 2>&1 || true
  "$SESSION_SH" phase-complete "$PHASE" >/dev/null 2>&1 || true
fi
