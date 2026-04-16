#!/usr/bin/env bash
# cache.sh — Small file-cache helpers used by nanostack libs.
# Source this file; the helpers expect $NANOSTACK_STORE to be set.
#
# Cache files live under "$NANOSTACK_STORE/.cache/". Set NANOSTACK_NO_CACHE=1
# to force callers to bypass caches (useful for debugging stale data).

# Cross-platform file mtime in epoch seconds. Echo 0 on failure.
nano_mtime() {
  local f="$1"
  [ -e "$f" ] || { echo 0; return; }
  if stat -f %m "$f" >/dev/null 2>&1; then
    stat -f %m "$f"
  elif stat -c %Y "$f" >/dev/null 2>&1; then
    stat -c %Y "$f"
  else
    echo 0
  fi
}

# Age of a file in seconds. Echo a very large number on failure so callers
# treat missing files as expired.
nano_cache_age() {
  local f="$1"
  if [ ! -f "$f" ]; then echo 999999999; return; fi
  local now mt
  now=$(date +%s 2>/dev/null || echo 0)
  mt=$(nano_mtime "$f")
  echo $(( now - mt ))
}

# Returns 0 if cache is fresh (age < ttl AND not invalidated by source mtime),
# 1 otherwise. Args: cache_file ttl_seconds [source_path_to_check_mtime_against]
nano_cache_fresh() {
  [ "${NANOSTACK_NO_CACHE:-0}" = "1" ] && return 1
  local cache="$1" ttl="$2" source="${3:-}"
  [ -f "$cache" ] || return 1
  local age
  age=$(nano_cache_age "$cache")
  [ "$age" -lt "$ttl" ] || return 1
  if [ -n "$source" ] && [ -e "$source" ]; then
    local src_mt cache_mt
    src_mt=$(nano_mtime "$source")
    cache_mt=$(nano_mtime "$cache")
    [ "$src_mt" -le "$cache_mt" ] || return 1
  fi
  return 0
}

nano_cache_dir() {
  local d="$NANOSTACK_STORE/.cache"
  mkdir -p "$d" 2>/dev/null || true
  echo "$d"
}

# Invalidate a named cache file. Safe if the file does not exist.
nano_cache_invalidate() {
  local name="$1"
  [ -z "$name" ] && return 0
  rm -f "$NANOSTACK_STORE/.cache/$name" 2>/dev/null || true
}
