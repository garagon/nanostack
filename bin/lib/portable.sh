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
#   nano_artifact_filename_epoch <path>
#                       Parse the canonical artifact filename timestamp
#                       (YYYYMMDD-HHMMSS.json, as written by save-artifact.sh)
#                       into epoch seconds. Returns 0 when the basename does
#                       not match the convention.

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

# Epoch seconds for the canonical artifact filename timestamp. save-artifact.sh
# names every artifact "$(date -u +%Y%m%d-%H%M%S).json", so the timestamp lives
# in the filename, not just in mtime. Trust-sensitive consumers (the phase gate)
# order by this rather than mtime: a copied or `touch`-ed stale artifact keeps
# its original filename timestamp even when its mtime is fresh. Returns 0 when
# the basename does not match the convention, so an unparseable name reads as
# "oldest" and fails a freshness check closed rather than passing on a bogus
# epoch. Bash 3.2 compatible; tries BSD `date` then GNU `date`, both in UTC.
nano_artifact_filename_epoch() {
  local path="$1" base stamp
  base=$(basename "$path")
  case "$base" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].json) ;;
    *) echo 0; return ;;
  esac
  stamp="${base%.json}"   # YYYYMMDD-HHMMSS
  local epoch roundtrip
  epoch=$(date -u -j -f "%Y%m%d-%H%M%S" "$stamp" +%s 2>/dev/null) \
    || epoch=$(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null) \
    || epoch=0
  [ -n "$epoch" ] || epoch=0
  if [ "$epoch" != 0 ]; then
    # Round-trip guard: BSD `date -j` silently normalizes impossible
    # calendar dates (20260231 -> 2026-03-03) instead of failing. Reformat
    # the epoch back and require it to equal the input, so a normalized or
    # otherwise invalid stamp fails closed (epoch 0 -> treated as oldest).
    roundtrip=$(date -u -j -f "%s" "$epoch" "+%Y%m%d-%H%M%S" 2>/dev/null) \
      || roundtrip=$(date -u -d "@$epoch" "+%Y%m%d-%H%M%S" 2>/dev/null) \
      || roundtrip=""
    [ "$roundtrip" = "$stamp" ] || epoch=0
  fi
  echo "$epoch"
}
