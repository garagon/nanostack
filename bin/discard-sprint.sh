#!/usr/bin/env bash
# discard-sprint.sh — Remove artifacts from a bad session
# Usage:
#   discard-sprint.sh                     # discard all artifacts from today for this project
#   discard-sprint.sh --phase review      # discard only review artifacts
#   discard-sprint.sh --date 2026-03-24   # discard artifacts from a specific date
#   discard-sprint.sh --dry-run           # show what would be deleted without deleting
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
. "$SCRIPT_DIR/lib/phases.sh"

STORE="$NANOSTACK_STORE"
KNOW_HOW="$STORE/know-how"
PROJECT="$(pwd)"
PROJECT_NAME=$(basename "$PROJECT")
DATE=$(date -u +"%Y-%m-%d")
PHASE=""
DRY_RUN=false
# Default to every registered phase (core + custom). The explicit
# --phase flag below narrows to a single phase when given.
PHASES=$(nano_all_phases)

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --date) DATE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# If --phase given, only clean that phase. Validate it against the registered
# phases first so a traversal or unknown selector cannot redirect the delete
# loop at "$STORE/$phase" outside the store.
if [ -n "$PHASE" ]; then
  # A phase is a single token. Reject whitespace, newlines, slashes, or ".."
  # first so a multiline value cannot slip a second word past the membership
  # check below (grep treats newlines as separate lines) and then split into a
  # path in the delete loop.
  case "$PHASE" in
    *[[:space:]]*|*/*|*..*)
      echo "ERROR: invalid phase '$PHASE' (expected a single phase name)" >&2
      exit 1
      ;;
  esac
  if ! printf '%s\n' $PHASES | grep -qxF -- "$PHASE"; then
    echo "ERROR: unknown phase '$PHASE' (not a registered phase)" >&2
    exit 1
  fi
  PHASES="$PHASE"
fi

# A date selector must be an exact YYYY-MM-DD so it cannot widen the filename
# match (e.g. "*") or carry path characters into the prefix.
case "$DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "ERROR: --date must be YYYY-MM-DD" >&2; exit 1 ;;
esac

# Convert date to prefix for matching artifact filenames (YYYYMMDD)
DATE_PREFIX=$(echo "$DATE" | tr -d '-')

DELETED=0

# Remove matching artifacts
for phase in $PHASES; do
  dir="$STORE/$phase"
  [ -d "$dir" ] || continue
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    # Check filename starts with date prefix
    case "$fname" in
      ${DATE_PREFIX}-*)
        # Check it belongs to this project
        if jq -e --arg p "$PROJECT" '.project == $p' "$f" >/dev/null 2>&1; then
          if $DRY_RUN; then
            echo "[dry-run] would delete: $f"
          else
            rm "$f"
            echo "deleted: $f"
          fi
          DELETED=$((DELETED + 1))
        fi
        ;;
    esac
  done
done

# Remove journal entry for that date if it exists
JOURNAL="$KNOW_HOW/journal/$DATE-$PROJECT_NAME.md"
if [ -f "$JOURNAL" ]; then
  if $DRY_RUN; then
    echo "[dry-run] would delete: $JOURNAL"
  else
    rm "$JOURNAL"
    echo "deleted: $JOURNAL"
  fi
  DELETED=$((DELETED + 1))
fi

if [ "$DELETED" -eq 0 ]; then
  echo "Nothing to discard for $PROJECT_NAME on $DATE."
else
  if $DRY_RUN; then
    echo "$DELETED file(s) would be deleted."
  else
    echo "$DELETED file(s) deleted."
  fi
fi
