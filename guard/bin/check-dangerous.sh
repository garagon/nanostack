#!/usr/bin/env bash
# Guard: check-dangerous.sh
# Called by Claude Code's PreToolUse hook on Bash commands.
# Receives the command to check via stdin or as $1.
# Exit 0 = safe, Exit 1 = dangerous (blocked/warned).
set -euo pipefail

CMD="${1:-$(cat)}"

# Patterns that are always dangerous
DANGEROUS_PATTERNS=(
  # Mass deletion
  'rm -rf /'
  'rm -rf ~'
  'rm -rf \.'
  'rm -rf \*'
  'find .* -delete'
  'find .* -exec rm'

  # Git history destruction
  'git reset --hard'
  'git push --force'
  'git push.*-f '
  'git push.*-f$'
  'git branch -D'
  'git clean -fd'
  'git checkout -- \.'

  # Database destruction
  'DROP TABLE'
  'DROP DATABASE'
  'TRUNCATE '
  'DELETE FROM .* [^W]*$'

  # Container/infra destruction
  'kubectl delete'
  'docker rm -f'
  'docker system prune'
  'docker volume prune'

  # Production indicators
  'prod.*deploy'
  'deploy.*prod'
  '--env.*production'
  '--environment.*production'
)

# Patterns that warrant warning but not blocking
WARNING_PATTERNS=(
  'rm -r '
  'git rebase'
  'git merge'
  'git stash drop'
  'chmod -R 777'
  'chown -R'
  'npm publish'
  'pip.*upload'
  'cargo publish'
)

check_patterns() {
  local cmd="$1"
  shift
  local patterns=("$@")
  for pattern in "${patterns[@]}"; do
    if echo "$cmd" | grep -qiE "$pattern"; then
      echo "$pattern"
      return 0
    fi
  done
  return 1
}

# Check dangerous patterns first
if match=$(check_patterns "$CMD" "${DANGEROUS_PATTERNS[@]}"); then
  echo "🛑 GUARD: Dangerous operation detected"
  echo "Command: $CMD"
  echo "Matched: $match"
  echo ""
  echo "This command could cause irreversible damage."
  echo "If you're sure, ask the user for explicit confirmation."
  exit 1
fi

# Check warning patterns
if match=$(check_patterns "$CMD" "${WARNING_PATTERNS[@]}"); then
  echo "⚠️  GUARD: Potentially risky operation"
  echo "Command: $CMD"
  echo "Matched: $match"
  echo ""
  echo "Consider the impact before proceeding."
  # Exit 0 — warn but don't block
  exit 0
fi

# Safe
exit 0
