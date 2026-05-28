#!/usr/bin/env bash
# run-harness.sh — Run nanostack CI harnesses from ci/harnesses.json.
#
# Harness Architecture vNext PR 3 (2026-05-28). The documented local
# full-gauntlet entry point. Reads the manifest, validates a suite's
# declared deps before running it, runs serially, and prints a result
# table. Returns non-zero if any selected suite fails.
#
# Usage:
#   ci/run-harness.sh --list
#   ci/run-harness.sh --suite <id> [--filter <pattern>]
#   ci/run-harness.sh --kind <kind>
#   ci/run-harness.sh --tier <tier>
#   ci/run-harness.sh --all
# Options:
#   --filter <pattern>   passed through to the suite (single --suite only)
#   --continue-on-fail   keep running after a suite fails
#   --dry-run            print what would run, run nothing
#   --json               emit a JSON summary instead of a table
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT/ci/harnesses.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "ERROR: $MANIFEST not found" >&2; exit 1; }

MODE=""; SELECT=""; FILTER=""; CONTINUE=false; DRYRUN=false; JSON=false
need_val() { [ "$1" -ge 2 ] || { echo "ERROR: $2 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --list)    MODE="list"; shift ;;
    --all)     MODE="all"; shift ;;
    --suite)   need_val "$#" --suite; MODE="suite"; SELECT="$2"; shift 2 ;;
    --kind)    need_val "$#" --kind;  MODE="kind"; SELECT="$2"; shift 2 ;;
    --tier)    need_val "$#" --tier;  MODE="tier"; SELECT="$2"; shift 2 ;;
    --filter)  need_val "$#" --filter; FILTER="$2"; shift 2 ;;
    --filter=*) FILTER="${1#*=}"; shift ;;
    --continue-on-fail) CONTINUE=true; shift ;;
    --dry-run) DRYRUN=true; shift ;;
    --json)    JSON=true; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "ERROR: pick one of --list --suite --kind --tier --all" >&2; exit 2; }

# Emit the selected suites as tab-separated id<TAB>path<TAB>kind<TAB>tier<TAB>deps(space).
select_suites() {
  case "$MODE" in
    list|all) jq -r '.suites[] | [.id,.path,.kind,.tier,(.deps|join(" "))] | @tsv' "$MANIFEST" ;;
    suite)    jq -r --arg s "$SELECT" '.suites[] | select(.id==$s) | [.id,.path,.kind,.tier,(.deps|join(" "))] | @tsv' "$MANIFEST" ;;
    kind)     jq -r --arg s "$SELECT" '.suites[] | select(.kind==$s) | [.id,.path,.kind,.tier,(.deps|join(" "))] | @tsv' "$MANIFEST" ;;
    tier)     jq -r --arg s "$SELECT" '.suites[] | select(.tier==$s) | [.id,.path,.kind,.tier,(.deps|join(" "))] | @tsv' "$MANIFEST" ;;
  esac
}

ROWS=$(select_suites)
if [ -z "$ROWS" ]; then
  echo "No suites matched ($MODE ${SELECT:-})." >&2
  exit 2
fi

if [ "$MODE" = "list" ]; then
  if $JSON; then
    jq '[.suites[] | {id,path,kind,tier,deps}]' "$MANIFEST"
    exit 0
  fi
  printf '%-32s %-16s %-8s %s\n' "SUITE" "KIND" "TIER" "PATH"
  printf '%s\n' "$ROWS" | while IFS=$'\t' read -r id path kind tier deps; do
    printf '%-32s %-16s %-8s %s\n' "$id" "$kind" "$tier" "$path"
  done
  exit 0
fi

deps_ok() {  # $1 = space-separated deps; echoes first missing or empty
  local d
  for d in $1; do command -v "$d" >/dev/null 2>&1 || { echo "$d"; return; }; done
  echo ""
}

# Parse a suite's own summary line for its check count (checks or cells).
parse_count() {
  printf '%s\n' "$1" | grep -oE '[0-9]+ (checks|cells) passed|[0-9]+/[0-9]+ checks passed' \
    | tail -1 | grep -oE '^[0-9]+' | head -1
}

OVERALL=0
RESULTS_JSON="[]"
printf '%s\n' "$ROWS" | { TABLE=""; while IFS=$'\t' read -r id path kind tier deps; do
  [ -z "$id" ] && continue
  if $DRYRUN; then
    if $JSON; then
      RESULTS_JSON=$(printf '%s' "$RESULTS_JSON" | jq --arg i "$id" --arg p "$path" --arg k "$kind" --arg t "$tier" \
        '. + [{suite:$i,path:$p,kind:$k,tier:$t,would_run:true}]')
    else
      printf 'would run: %-30s %-12s %-8s %s\n' "$id" "$kind" "$tier" "$path"
    fi
    continue
  fi
  missing=$(deps_ok "$deps")
  if [ -n "$missing" ]; then
    $JSON || printf '%-28s %-7s %-7s %s\n' "$id" "-" "SKIP" "(missing dep: $missing)"
    RESULTS_JSON=$(printf '%s' "$RESULTS_JSON" | jq --arg i "$id" '. + [{suite:$i,result:"skip"}]')
    continue
  fi
  start=$(date +%s)
  if [ "$MODE" = "suite" ] && [ -n "$FILTER" ]; then
    out=$(bash "$ROOT/$path" --filter "$FILTER" 2>&1); rc=$?
  else
    out=$(bash "$ROOT/$path" 2>&1); rc=$?
  fi
  end=$(date +%s)
  secs=$((end - start))
  count=$(parse_count "$out"); count="${count:-?}"
  if [ "$rc" -eq 0 ]; then result="pass"; else result="FAIL"; OVERALL=1; fi
  if ! $JSON; then
    printf '%-28s %-7s %-7s %ss\n' "$id" "$count" "$result" "$secs"
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | tail -20
  fi
  RESULTS_JSON=$(printf '%s' "$RESULTS_JSON" | jq --arg i "$id" --arg c "$count" --arg r "$result" --argjson s "$secs" \
    '. + [{suite:$i,checks:$c,result:$r,seconds:$s}]')
  if [ "$rc" -ne 0 ] && [ "$CONTINUE" = "false" ]; then
    break
  fi
done
if $DRYRUN; then
  $JSON && jq -n --argjson r "$RESULTS_JSON" '{dry_run:true, results:$r}'
  exit 0
fi
if $JSON; then
  jq -n --argjson r "$RESULTS_JSON" --argjson ok "$OVERALL" '{results:$r, failed: ($ok==1)}'
fi
exit "$OVERALL"; }
