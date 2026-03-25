#!/usr/bin/env bash
# suggest-security.sh — PostToolUse hook for /review
# After review completes, check if changed files touch security-sensitive paths
# If so, suggest running /security
set -e

# Get changed files
CHANGED=$(git diff --name-only --cached 2>/dev/null; git diff --name-only 2>/dev/null)

# Check for security-sensitive patterns
SENSITIVE_PATTERNS="auth|login|password|token|secret|\.env|middleware|permission|role|session|jwt|oauth|payment|billing|stripe|crypto|encrypt|Dockerfile|docker-compose|\.github/workflows|k8s|terraform|infra"

MATCHES=$(echo "$CHANGED" | grep -iE "$SENSITIVE_PATTERNS" || true)

if [ -n "$MATCHES" ]; then
  echo "SECURITY_SENSITIVE"
  echo "$MATCHES"
else
  echo "CLEAN"
fi
