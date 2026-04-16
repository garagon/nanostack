#!/usr/bin/env bash
# portable.sh — Cross-platform wrappers for shell tools that have different
# names or flags on macOS (BSD) vs Linux (GNU). Source this file from any
# script that needs sha256 or file mtime.
#
# History: each of these was added piecemeal in earlier rounds (sha256 in V3
# for /conductor, mtime in V1 for the cache helpers). Centralizing them here
# stops the next portability bug from being fixed in one site and forgotten
# in three others.
#
# Functions exposed:
#   nano_sha256         Read stdin, write hex hash + "  -" to stdout (matches
#                       both `sha256sum` and `shasum -a 256` output format).
#   nano_mtime <path>   Print the file's mtime as epoch seconds, or 0 if the
#                       file is missing or stat fails.

# Hash a stream from stdin. Prefers sha256sum (Linux default), falls back to
# shasum -a 256 (macOS / perl-shasum). Without one of the two, scripts that
# use this should treat the missing hash as a hard error, not a silent skip.
nano_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    echo "ERROR: neither sha256sum nor shasum available" >&2
    return 1
  fi
}

# File mtime as epoch seconds. Returns 0 on missing file or stat failure so
# callers that compare timestamps fall back to "treat as old" rather than
# crashing. Handles BSD (macOS) and GNU (Linux) stat.
nano_mtime() {
  local f="$1"
  [ -e "$f" ] || { echo 0; return; }
  if stat -c %Y "$f" >/dev/null 2>&1; then
    stat -c %Y "$f"
  elif stat -f %m "$f" >/dev/null 2>&1; then
    stat -f %m "$f"
  else
    echo 0
  fi
}
