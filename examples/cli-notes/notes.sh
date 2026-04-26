#!/usr/bin/env bash
# notes.sh — tiny note CLI for the cli-notes example.
#
# This script is intentionally minimal. It does NOT cover every case
# you would want in a real notes tool. The gaps are the seeds for
# your first nanostack sprint on this project: see README.md for
# three concrete feature ideas.
#
# Storage is a single text file (notes.txt) in this directory.
# One line per note, prefixed with an ISO 8601 UTC timestamp.
#
# Usage:
#   notes.sh add "your note text"   append a timestamped note
#   notes.sh list                    print every note in the order written
#   notes.sh count                   print how many notes exist
#
# Examples:
#   ./notes.sh add "buy milk"
#   ./notes.sh list
#   ./notes.sh count
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTES_FILE="$SCRIPT_DIR/notes.txt"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

cmd_add() {
  local text="${1:-}"
  if [ -z "$text" ]; then
    echo "ERROR: 'add' requires note text. Try: notes.sh add \"buy milk\"" >&2
    exit 1
  fi
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s  %s\n' "$ts" "$text" >> "$NOTES_FILE"
  echo "ok"
}

cmd_list() {
  if [ ! -f "$NOTES_FILE" ] || [ ! -s "$NOTES_FILE" ]; then
    echo "(no notes yet)"
    return 0
  fi
  cat "$NOTES_FILE"
}

cmd_count() {
  if [ ! -f "$NOTES_FILE" ]; then
    echo "0"
    return 0
  fi
  wc -l < "$NOTES_FILE" | tr -d ' '
}

CMD="${1:-}"
shift || true

case "$CMD" in
  add)   cmd_add   "$@" ;;
  list)  cmd_list  "$@" ;;
  count) cmd_count "$@" ;;
  -h|--help|help|"") usage 0 ;;
  *)     echo "Unknown command: $CMD" >&2; usage 1 ;;
esac
