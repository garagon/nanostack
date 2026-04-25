#!/usr/bin/env bash
# check-write.sh — PreToolUse hook for Write and Edit tools.
#
# Claude Code's Bash tool already runs through check-dangerous.sh. The
# Write and Edit tools did not have an equivalent gate, which meant an
# agent with Write(*)/Edit(*) permissions could touch ~/.ssh/id_rsa,
# /etc/passwd, or .env.production with no guard involvement. This hook
# adds a narrow denylist so those paths stay off-limits regardless of
# how broad the permission list is.
#
# Input contract:
#   Claude Code PreToolUse hooks receive JSON on stdin with shape:
#     {"tool_name": "Write" | "Edit" | "MultiEdit",
#      "tool_input": {"file_path": "<path>", ...}}
#   For direct invocation (tests, local checks) accept the path as $1.
#
# Exit codes:
#   0  = allow
#   1  = block (path matches deny pattern)
#
# Philosophy: narrow denylist, not broad allowlist. Coding agents need
# to write code freely within the project. The goal is to keep them
# away from secrets and system files, not to reshape the permission
# model around every working directory.

set -u

# ─── Extract file path ─────────────────────────────────────────────────

INPUT="${1:-}"
if [ -z "$INPUT" ] && [ -p /dev/stdin ]; then
  INPUT=$(cat)
fi

FILE_PATH=""
if [ -n "$INPUT" ]; then
  # If it parses as JSON, pull tool_input.file_path. Otherwise treat the
  # whole input as the path (supports both the hook contract and direct
  # invocation from tests or CI).
  if printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '
      .tool_input.file_path
      // .tool_input.notebook_path
      // .file_path
      // empty
    ')
  else
    FILE_PATH="$INPUT"
  fi
fi

# Nothing to check means nothing to block. Agents that call Write/Edit
# with no file_path will fail later in the tool itself.
[ -n "$FILE_PATH" ] || exit 0

# Expand ~ to $HOME for path-prefix matching.
case "$FILE_PATH" in
  "~"*) FILE_PATH="$HOME${FILE_PATH#~}" ;;
esac

# Resolve symlinks. A repo-controlled symlink like myfile -> /etc/passwd
# or sshlink -> ~/.ssh otherwise lets a Write/Edit reach a protected
# target whose textual path does not match any denylist entry. The fix
# is to evaluate the denylist against BOTH the original path and its
# resolved form; if either matches, block. Falls back to a pure-bash
# parent-realpath when the realpath binary is missing or refuses
# missing leaves (Write to a not-yet-existing file).
RESOLVED_PATH=""
if command -v realpath >/dev/null 2>&1; then
  RESOLVED_PATH=$(realpath -m "$FILE_PATH" 2>/dev/null) \
    || RESOLVED_PATH=$(realpath --canonicalize-missing "$FILE_PATH" 2>/dev/null) \
    || RESOLVED_PATH=""
fi
if [ -z "$RESOLVED_PATH" ]; then
  # Pure-bash fallback. cd into the parent (which IS a real dir even
  # when the leaf is being created) and re-attach the basename. pwd -P
  # follows symlinks at the parent level, which catches sshlink/...
  _parent=$(dirname "$FILE_PATH")
  _base=$(basename "$FILE_PATH")
  if RESOLVED_PARENT=$(cd "$_parent" 2>/dev/null && pwd -P); then
    RESOLVED_PATH="$RESOLVED_PARENT/$_base"
  else
    RESOLVED_PATH="$FILE_PATH"
  fi
  unset _parent _base RESOLVED_PARENT
fi

# ─── Deny patterns ─────────────────────────────────────────────────────
# Each entry is a POSIX extended regex evaluated against the absolute or
# relative file path. Intentionally narrow: false positives train users
# to ignore the block, and this hook cannot afford that.

# Basename-based patterns (match any path ending in this filename).
BASENAME_DENY=(
  # Environment files that typically contain real secrets.
  '\.env$'
  '\.env\.local$'
  '\.env\.production$'
  '\.env\.prod$'
  '\.env\.staging$'
  '\.env\.development$'
  '\.env\.dev$'
  # Private cryptographic material.
  '\.pem$'
  '\.key$'
  '\.p12$'
  '\.pfx$'
  # SSH keys and config.
  'id_rsa$'
  'id_rsa\.pub$'
  'id_ed25519$'
  'id_ed25519\.pub$'
  'id_ecdsa$'
  'id_dsa$'
  'authorized_keys$'
  'known_hosts$'
  # Shell history (often contains secrets).
  '\.bash_history$'
  '\.zsh_history$'
  '\.python_history$'
)

# Path-prefix patterns (match if the absolute path starts with this).
PATH_PREFIX_DENY=(
  '^/etc/'
  '^/var/'
  '^/usr/bin/'
  '^/usr/sbin/'
  '^/usr/lib/'
  '^/System/'
  '^/private/etc/'
  "^$HOME/\\.ssh/"
  "^$HOME/\\.gnupg/"
  "^$HOME/\\.aws/"
  "^$HOME/\\.gcp/"
  "^$HOME/\\.config/gcloud/"
  "^$HOME/\\.kube/"
)

# ─── Evaluate ──────────────────────────────────────────────────────────
# Run the denylist against both the original FILE_PATH and the symlink
# RESOLVED_PATH. Either match blocks. This closes the symlink-bypass
# class where a path like /tmp/sshlink/config (sshlink -> ~/.ssh) does
# not textually match ^$HOME/.ssh/ but resolves to a protected target.

MATCHED_RULE=""
MATCHED_PATH=""

check_path() {
  local p="$1" pat
  for pat in "${BASENAME_DENY[@]}"; do
    if printf '%s' "$p" | grep -qE -- "$pat"; then
      MATCHED_RULE="secret_basename:$pat"
      MATCHED_PATH="$p"
      return 0
    fi
  done
  for pat in "${PATH_PREFIX_DENY[@]}"; do
    if printf '%s' "$p" | grep -qE -- "$pat"; then
      MATCHED_RULE="system_path:$pat"
      MATCHED_PATH="$p"
      return 0
    fi
  done
  return 1
}

check_path "$FILE_PATH"
if [ -z "$MATCHED_RULE" ] && [ -n "$RESOLVED_PATH" ] && [ "$RESOLVED_PATH" != "$FILE_PATH" ]; then
  check_path "$RESOLVED_PATH"
fi

if [ -n "$MATCHED_RULE" ]; then
  cat >&2 <<EOF
BLOCKED [W-001] Write or Edit to a protected path
Category: ${MATCHED_RULE%%:*}
Path:     $FILE_PATH
Resolved: $RESOLVED_PATH
Matched:  $MATCHED_PATH
Rule:     ${MATCHED_RULE#*:}

This file holds secrets or system state. Coding agents should not
modify it. Edit the file by hand if the change is intentional, or
tell the agent to write to a non-protected path.

See SECURITY.md "Permission model" for the full list.
EOF
  exit 1
fi

# Allowed. Write/Edit tool proceeds normally.
exit 0
