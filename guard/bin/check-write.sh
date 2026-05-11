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
# resolver when the realpath binary is missing or refuses missing
# leaves (Write to a not-yet-existing file).
#
# Three resolution paths:
#   1. GNU realpath -m / --canonicalize-missing follows every symlink
#      including the leaf. Best when available (Ubuntu, macOS+coreutils).
#   2. macOS BSD realpath (no -m) accepts only existing paths. Try it
#      anyway: leaf symlinks created in this test get resolved.
#   3. Pure-bash fallback: resolve the parent via `cd && pwd -P`, then
#      if the leaf itself is a symlink, follow it manually with
#      readlink. Relative readlink targets resolve against the
#      already-resolved parent. This closes the macOS-without-coreutils
#      bypass where `ln -s /etc/passwd leaf-link` could reach the
#      target unguarded.
RESOLVED_PATH=""
if command -v realpath >/dev/null 2>&1; then
  RESOLVED_PATH=$(realpath -m "$FILE_PATH" 2>/dev/null) \
    || RESOLVED_PATH=$(realpath --canonicalize-missing "$FILE_PATH" 2>/dev/null) \
    || RESOLVED_PATH=$(realpath "$FILE_PATH" 2>/dev/null) \
    || RESOLVED_PATH=""
fi
if [ -z "$RESOLVED_PATH" ]; then
  _parent=$(dirname "$FILE_PATH")
  _base=$(basename "$FILE_PATH")
  if RESOLVED_PARENT=$(cd "$_parent" 2>/dev/null && pwd -P); then
    RESOLVED_PATH="$RESOLVED_PARENT/$_base"
    # If the leaf exists and is a symlink, follow it manually so the
    # denylist sees the target. readlink without flags is portable
    # across BSD and GNU; -f / -e are GNU-only.
    if [ -L "$RESOLVED_PATH" ]; then
      _target=$(readlink "$RESOLVED_PATH" 2>/dev/null)
      if [ -n "$_target" ]; then
        case "$_target" in
          /*) RESOLVED_PATH="$_target" ;;
          *)  RESOLVED_PATH="$RESOLVED_PARENT/$_target" ;;
        esac
        # Collapse a single layer of /a/../b that the manual splice
        # may introduce. cd into the new parent and re-attach base if
        # possible; if the directory does not exist (target points at
        # a not-yet-created path) keep the textual form so the
        # denylist still has something to match.
        _new_parent=$(dirname "$RESOLVED_PATH")
        _new_base=$(basename "$RESOLVED_PATH")
        if _NEW_PARENT_REAL=$(cd "$_new_parent" 2>/dev/null && pwd -P); then
          RESOLVED_PATH="$_NEW_PARENT_REAL/$_new_base"
        fi
        unset _target _new_parent _new_base _NEW_PARENT_REAL
      fi
    fi
  else
    RESOLVED_PATH="$FILE_PATH"
  fi
  unset _parent _base RESOLVED_PARENT
fi

# ─── Deny patterns ─────────────────────────────────────────────────────
# Each entry is a POSIX extended regex evaluated against the absolute or
# relative file path. Intentionally narrow: false positives train users
# to ignore the block, and this hook cannot afford that.
#
# PR 7 of the 2026-05-10 architecture audit: closed the gap where read
# guard (G-035 in guard/rules.json) blocked credential JSON basenames
# but write/edit allowed them. The deny list now mirrors the read
# side for credential JSON files; templates (.env.example,
# credentials.example.json, service-account.template.json, etc.) are
# explicitly allowed through TEMPLATE_ALLOW so first-run onboarding
# does not fight the guard.

# Template basenames that should ALWAYS pass through, even when the
# rest of the filename looks like a secret. Runs before the deny
# matcher. Matches the common ".example", ".sample", ".template"
# infix that signals "documentation copy, no secrets".
TEMPLATE_ALLOW=(
  '\.example$'
  '\.sample$'
  '\.template$'
  '\.example\.[a-zA-Z0-9]+$'
  '\.sample\.[a-zA-Z0-9]+$'
  '\.template\.[a-zA-Z0-9]+$'
)

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
  '\.env\.test$'
  # Credential JSON files. Mirrors the read-side deny added in PR
  # #195 (G-035 in guard/rules.json). The shapes cover the common
  # SDK conventions: credentials.json, secrets.json, service-account
  # /service_account, firebase-adminsdk, google-credentials,
  # gcp-credentials, aws-credentials, supabase-service-role,
  # client-secret(s) / client_secret. Word-separator is optional so
  # names without a hyphen/underscore (serviceaccount.json,
  # firebaseadminsdk.json, googlecredentials.json, clientsecret.json)
  # are caught too. Codex flagged the missing separator-less forms
  # on the PR 7 first review pass.
  '(^|/)credentials?\.json$'
  '(^|/)secrets?\.json$'
  '(^|/)service[-_]?account[^/]*\.json$'
  '(^|/)firebase[-_]?adminsdk[^/]*\.json$'
  '(^|/)google[-_]?credentials[^/]*\.json$'
  '(^|/)gcp[-_]?credentials[^/]*\.json$'
  '(^|/)aws[-_]?credentials[^/]*\.json$'
  '(^|/)supabase[-_]?service[-_]?role[^/]*\.json$'
  '(^|/)client[-_]?secret[s]?[^/]*\.json$'
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
  # Template short-circuit: files whose basename ends in `.example`,
  # `.sample`, `.template` (with or without an extension after) pass
  # the BASENAME deny check, even when the rest of the name matches a
  # credential pattern. This is the safe surface for first-run
  # onboarding (credentials.example.json, service-account.template.
  # json, .env.example, etc.).
  #
  # The template exemption deliberately does NOT apply to
  # PATH_PREFIX_DENY: a write to $HOME/.ssh/config.example or
  # /etc/foo.template must still block because the protected
  # directory is what makes the path sensitive, not the filename.
  # Codex flagged the over-broad exemption on the PR 7 first review
  # pass.
  local base is_template=false
  base=$(basename "$p")
  for pat in "${TEMPLATE_ALLOW[@]}"; do
    if printf '%s' "$base" | grep -qE -- "$pat"; then
      is_template=true
      break
    fi
  done
  if [ "$is_template" = false ]; then
    for pat in "${BASENAME_DENY[@]}"; do
      if printf '%s' "$p" | grep -qE -- "$pat"; then
        MATCHED_RULE="secret_basename:$pat"
        MATCHED_PATH="$p"
        return 0
      fi
    done
  fi
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
