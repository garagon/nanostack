#!/usr/bin/env bash
# suggest-security.sh — PostToolUse hook for /review
# After review completes, check if changed files touch security-sensitive paths
# If so, suggest running /security
set -e

# Detect git context
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../bin/lib/git-context.sh" 2>/dev/null || true
GIT_MODE=$(detect_git_mode 2>/dev/null || echo "local")

# Get changed files (git or find fallback)
if [ "$GIT_MODE" = "local" ]; then
  CHANGED=$(find . -maxdepth 3 -type f -not -path '*/node_modules/*' -not -path '*/.nanostack/*' -not -path '*/.git/*' -not -path '*/.DS_Store' 2>/dev/null)
else
  CHANGED=$(git diff --name-only --cached 2>/dev/null; git diff --name-only 2>/dev/null)
fi

# Check for security-sensitive patterns
SENSITIVE_PATTERNS="auth|login|password|token|secret|\.env|middleware|permission|role|session|jwt|oauth|payment|billing|stripe|crypto|encrypt|Dockerfile|docker-compose|\.github/workflows|k8s|terraform|infra"

MATCHES=$(echo "$CHANGED" | grep -iE "$SENSITIVE_PATTERNS" || true)

if [ -n "$MATCHES" ]; then
  echo "SECURITY_SENSITIVE"
  echo "$MATCHES"
else
  echo "CLEAN"
fi
