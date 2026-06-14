#!/usr/bin/env bash
# session-lock.sh — atomic, trap-safe advisory lock for session.json writes.
#
# Architecture review round (2026-06-11). Before this lib, only
# session.sh phase-start held a lock around its read-modify-write of
# session.json; phase-complete, archive, init, and budget.sh all mutated
# the same file with no lock. Two agents (e.g. /conductor running phases
# in parallel) could interleave their `jq … > tmp; mv tmp session.json`
# and silently drop one update. The lock was also released by an explicit
# `rm -rf` at each return path, so a jq failure between acquire and
# release leaked the lockdir and wedged every later writer for 30s.
#
# This is the single primitive every session.json writer now shares:
#   nano_session_lock "$SESSION_FILE"   # blocks until held; fails closed at 30s
#   …read-modify-write…
#   nano_session_unlock                 # idempotent
#
# Properties:
#   - Atomic via mkdir (every POSIX filesystem). flock is intentionally
#     not used: stock macOS has no flock(1).
#   - Trap-safe: acquiring installs an EXIT/INT/TERM trap that releases
#     the lock, so a mid-write crash cannot leak the lockdir. Callers
#     should therefore NOT register their own EXIT trap after locking.
#   - Stale-owner reclaim: the holder records its PID in <lockdir>/owner;
#     a waiter whose owner PID is gone reclaims the lock. A missing owner
#     file is treated conservatively as a live holder.
#   - Bash 3.2 compatible; safe under set -e (the acquire loop never
#     aborts the caller on a failed mkdir).

# Idempotent: safe to source more than once in a process.
if [ "${_NANO_SESSION_LOCK_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_NANO_SESSION_LOCK_LOADED=1

# Path of the lockdir currently held by THIS process, or "" when unlocked.
_NANO_SESSION_LOCKDIR=""

# nano_session_lock <session_file>
# Blocks until the lock is held. Fails closed (exit 1) after 30s of live
# contention rather than racing the current writer.
nano_session_lock() {
  local session_file="${1:?nano_session_lock requires the session file path}"
  local lockdir="${session_file}.lockdir"
  local waited=0 owner_pid=""

  while ! mkdir "$lockdir" 2>/dev/null; do
    waited=$((waited + 1))

    # Once per second, check whether the lockholder is still alive. If the
    # owner file names a PID that no longer exists, the holder crashed or
    # exited mid-write and we reclaim the lock. A live PID means real
    # contention, so keep waiting. Missing owner file is treated as live.
    if [ $((waited % 10)) -eq 0 ] && [ -f "$lockdir/owner" ]; then
      owner_pid=$(cat "$lockdir/owner" 2>/dev/null)
      if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null || true
        echo "INFO: previous session lockholder (pid $owner_pid) is gone, reclaiming" >&2
        continue
      fi
    fi

    if [ "$waited" -gt 300 ]; then
      echo "ERROR: session lock held >30s (owner pid ${owner_pid:-unknown}). Retry after the other agent finishes, or remove $lockdir if nothing is running." >&2
      exit 1
    fi
    sleep 0.1
  done

  _NANO_SESSION_LOCKDIR="$lockdir"
  # Release on any exit path so a failed read-modify-write cannot leak the
  # lock. Callers must not install their own EXIT trap after locking.
  trap 'nano_session_unlock' EXIT INT TERM

  # Record ownership so a waiter can detect a stale lock if we crash.
  # Best-effort: if the write fails the lock still works for liveness
  # (waiters fall back to the conservative "live" treatment).
  echo "$$" > "$lockdir/owner" 2>/dev/null || true
}

# nano_session_unlock — release the lock held by this process. Idempotent:
# safe to call when nothing is held, and safe to call twice (the EXIT trap
# may fire after an explicit call).
nano_session_unlock() {
  if [ -n "$_NANO_SESSION_LOCKDIR" ]; then
    rm -rf "$_NANO_SESSION_LOCKDIR" 2>/dev/null || true
    _NANO_SESSION_LOCKDIR=""
  fi
}
