#!/usr/bin/env bash
# check-harness-manifest.sh — Validate ci/harnesses.json against reality.
#
# Harness Architecture vNext PR 3 (2026-05-28). The manifest is only useful
# if it cannot drift from the real harness files and workflows. This is a
# STATIC consistency check: it never runs a heavy suite. It fails closed on
# any of the drift directions below so an unregistered suite, a dead path,
# missing metadata, or a stale workflow reference cannot ship silently.
#
# Checks:
#   - manifest is valid JSON with a suites array
#   - every suite has id, path, kind, tier, deps (non-empty string[]),
#     expected_checks (number), surface (non-empty string[])
#   - kind in {unit,static-contract,runtime-e2e,visual-e2e,example-e2e}
#   - tier in {pr,opt-in,local}
#   - suite ids are unique
#   - every manifest path exists on disk
#   - every ci/e2e-*.sh and ci/check-*.sh on disk is registered
#   - tests/run.sh is registered (the spec requires it to be classified)
#   - for a suite with workflow+job, the workflow file exists and declares
#     that job key
#   - no workflow `run:` line invokes a ci/(e2e|check)-*.sh path that does
#     not exist on disk (no job points at a deleted harness)
#
# Exit 0 = consistent, exit 1 = any drift.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT/ci/harnesses.json"
WORKFLOWS="$ROOT/.github/workflows"

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required"; exit 1; }
[ -f "$MANIFEST" ] || { echo "FAIL: $MANIFEST does not exist"; exit 1; }
if ! jq -e '.suites | type == "array" and length > 0' "$MANIFEST" >/dev/null 2>&1; then
  echo "FAIL: $MANIFEST is not valid JSON with a non-empty .suites array"
  exit 1
fi

KIND_ENUM="unit static-contract runtime-e2e visual-e2e example-e2e"
TIER_ENUM="pr opt-in local"
in_enum() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Echo the trigger keys under a workflow's top-level `on:` (handles the
# block form used here, plus a simple inline `on: [push]` form).
workflow_triggers() {
  awk '
    /^[A-Za-z_][A-Za-z0-9_-]*:/ { ison = ($0 ~ /^on:/) ? 1 : 0 }
    ison && /^on:[[:space:]]*[^[:space:]#]/ { l=$0; sub(/^on:[[:space:]]*/,"",l); gsub(/[][,]/," ",l); print l }
    ison && /^  [A-Za-z0-9_-]+:/ { k=$0; sub(/^  /,"",k); sub(/:.*/,"",k); print k }
  ' "$1" | tr '\n' ' '
}

# True if the workflow declares <job> as a key under the top-level `jobs:`
# map. Scoped to jobs: so an `on:` event key (e.g. workflow_dispatch) at the
# same 2-space indent is never mistaken for a job.
workflow_has_job() {
  local wf="$1" job="$2"
  [ -f "$wf" ] || return 1
  awk -v want="$job" '
    /^[A-Za-z_][A-Za-z0-9_-]*:/ { injobs = ($0 ~ /^jobs:[[:space:]]*$/) ? 1 : 0; next }
    injobs && /^  [A-Za-z0-9_-]+:/ { k=$0; sub(/^  /,"",k); sub(/:.*/,"",k); if (k==want) found=1 }
    END { exit (found?0:1) }
  ' "$wf"
}

# True if the named job's body actually runs the suite, either by invoking
# the declared <path> directly or via the runner (ci/run-harness.sh ... <id>).
# Existence of the job key is not enough: a job that no longer calls the
# harness means CI coverage silently vanished.
job_runs_path() {
  local wf="$1" job="$2" path="$3" id="$4" run_block esc pre end rh
  # Extract ONLY the run: command content of the job's steps, so a path
  # that appears as data (an `uses:`/`with: path:` value, an env value, a
  # step name:) is never mistaken for an invocation. Handles inline
  # `run: cmd` and block-scalar `run: |` (body indented past the run: key).
  # (A heredoc inside a run: that merely writes the path into a file is a
  # known, unhandled exotic edge; not used by these workflows.)
  run_block=$(awk -v job="$job" '
    function ind(s){ match(s,/^ */); return RLENGTH }
    $0 ~ "^  "job":[[:space:]]*$" { inj=1; next }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { inj=0 }
    !inj { next }
    /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>][[:space:]]*$/ { inrun=1; ri=ind($0); next }
    /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[^|>[:space:]]/ {
      l=$0; sub(/^[[:space:]]*-?[[:space:]]*run:[[:space:]]*/,"",l); print l; inrun=0; next
    }
    inrun {
      if ($0 ~ /^[[:space:]]*$/) next
      if (ind($0) > ri) print; else inrun=0
    }
  ' "$wf" | grep -vE '^[[:space:]]*#')
  # Within run: content, the path counts only at command position. This
  # rejects chmod/cat/echo prep and `bash -n` syntax checks. Shape:
  #   <indent> [- ] [bash|sh ] [./] <path> <end-of-token>
  esc=$(printf '%s' "$path" | sed 's/[][\\.*^$()+?{}|]/\\&/g')
  pre='^[[:space:]]*(-[[:space:]]+)?((bash|sh)[[:space:]]+)?(\./)?'
  end='([[:space:]"'"'"');|&]|$)'
  printf '%s\n' "$run_block" | grep -qE "${pre}${esc}${end}" && return 0
  # Or via the runner with THIS suite id as a --suite argument, on a line
  # that is NOT a non-executing runner mode (--dry-run/--list/--help/-h).
  rh='ci/run-harness\.sh'
  local runner_lines
  runner_lines=$(printf '%s\n' "$run_block" | grep -E "${pre}${rh}([[:space:]].*)?--suite[ =]+${id}${end}")
  if [ -n "$runner_lines" ]; then
    printf '%s\n' "$runner_lines" | grep -qvE -- '--dry-run|--list|--help|[[:space:]]-h([[:space:]]|$)' && return 0
  fi
  return 1
}

# ── Per-suite metadata validation ──────────────────────────────────────
SEEN_IDS=""
SEEN_PATHS=""
COUNT=$(jq '.suites | length' "$MANIFEST")
i=0
while [ "$i" -lt "$COUNT" ]; do
  suite=$(jq -c ".suites[$i]" "$MANIFEST")
  i=$((i+1))
  id=$(printf '%s' "$suite" | jq -r '.id // ""')
  path=$(printf '%s' "$suite" | jq -r '.path // ""')
  label="${id:-<index $((i-1))>}"

  for field in id path kind tier; do
    v=$(printf '%s' "$suite" | jq -r --arg f "$field" '.[$f] // ""')
    [ -n "$v" ] || fail "suite $label missing string field: $field"
  done
  printf '%s' "$suite" | jq -e '.expected_checks | type == "number"' >/dev/null 2>&1 \
    || fail "suite $label missing numeric field: expected_checks"
  printf '%s' "$suite" | jq -e '.deps | type == "array" and length > 0 and all(type == "string" and length > 0)' >/dev/null 2>&1 \
    || fail "suite $label deps must be a non-empty array of strings"
  printf '%s' "$suite" | jq -e '.surface | type == "array" and length > 0 and all(type == "string" and length > 0)' >/dev/null 2>&1 \
    || fail "suite $label surface must be a non-empty array of strings"

  kind=$(printf '%s' "$suite" | jq -r '.kind // ""')
  tier=$(printf '%s' "$suite" | jq -r '.tier // ""')
  [ -z "$kind" ] || in_enum "$kind" "$KIND_ENUM" || fail "suite $label kind '$kind' not in enum ($KIND_ENUM)"
  [ -z "$tier" ] || in_enum "$tier" "$TIER_ENUM" || fail "suite $label tier '$tier' not in enum ($TIER_ENUM)"

  if [ -n "$id" ]; then
    case " $SEEN_IDS " in *" $id "*) fail "duplicate suite id: $id" ;; esac
    SEEN_IDS="$SEEN_IDS $id"
  fi

  if [ -n "$path" ]; then
    SEEN_PATHS="$SEEN_PATHS $path"
    [ -f "$ROOT/$path" ] || fail "suite $label path does not exist: $path"
  fi

  # Workflow/job consistency. pr/opt-in suites MUST be CI-wired (declare a
  # workflow + job that actually runs them); only local suites may omit it.
  wf=$(printf '%s' "$suite" | jq -r '.workflow // ""')
  job=$(printf '%s' "$suite" | jq -r '.job // ""')
  if [ "$tier" = "local" ] && { [ -n "$wf" ] || [ -n "$job" ]; }; then
    fail "suite $label is tier=local but declares workflow/job; local suites must not be CI-wired"
  elif [ -n "$wf" ] || [ -n "$job" ]; then
    if [ -z "$wf" ] || [ -z "$job" ]; then
      fail "suite $label must declare both workflow and job, or neither"
    elif [ ! -f "$ROOT/$wf" ]; then
      fail "suite $label references missing workflow file: $wf"
    elif ! workflow_has_job "$ROOT/$wf" "$job"; then
      fail "suite $label references job '$job' not found in $wf"
    elif ! job_runs_path "$ROOT/$wf" "$job" "$path" "$id"; then
      fail "suite $label job '$job' in $wf does not run $path (no direct call and no run-harness --suite $id)"
    else
      # Tier must match the workflow's real triggers, so a pr suite cannot
      # point at a workflow_dispatch-only workflow (claimed continuous but
      # never scheduled) and an opt-in suite cannot live in a pr-triggered
      # workflow (would run continuously). This preserves the adapter
      # evidence distinction between continuous and manual jobs.
      trigs=$(workflow_triggers "$ROOT/$wf")
      case "$tier" in
        pr)
          # pr = continuous on both events the contract names.
          case " $trigs " in
            *" pull_request "*) ;;
            *) fail "suite $label is tier=pr but $wf has no pull_request trigger (triggers: $trigs)" ;;
          esac
          case " $trigs " in
            *" push "*) ;;
            *) fail "suite $label is tier=pr but $wf has no push trigger (triggers: $trigs)" ;;
          esac ;;
        opt-in)
          # opt-in must be MANUAL-ONLY: workflow_dispatch present, and every
          # trigger allow-listed to a manual one. Any automatic trigger
          # (pull_request, push, schedule, merge_group, ...) breaks the
          # manual-vs-continuous contract.
          case " $trigs " in
            *" workflow_dispatch "*|*" workflow_call "*) ;;
            *) fail "suite $label is tier=opt-in but $wf has no manual trigger (workflow_dispatch/workflow_call; triggers: $trigs)" ;;
          esac
          for t in $trigs; do
            case " workflow_dispatch workflow_call " in
              *" $t "*) ;;
              *) fail "suite $label is tier=opt-in but $wf has a non-manual trigger '$t' (opt-in must be manual-only)" ;;
            esac
          done ;;
      esac
    fi
  elif [ "$tier" != "local" ]; then
    fail "suite $label (tier $tier) must declare workflow and job; only local suites may omit CI wiring"
  fi
done

# ── Every ci/e2e-*.sh and ci/check-*.sh on disk must be registered ─────
for f in "$ROOT"/ci/e2e-*.sh "$ROOT"/ci/check-*.sh; do
  [ -f "$f" ] || continue
  rel="ci/$(basename "$f")"
  case " $SEEN_PATHS " in
    *" $rel "*) ;;
    *) fail "unregistered harness (add it to ci/harnesses.json): $rel" ;;
  esac
done

# ── every tests/*.sh harness must be classified in the manifest ────────
for f in "$ROOT"/tests/*.sh; do
  [ -f "$f" ] || continue
  rel="tests/$(basename "$f")"
  case " $SEEN_PATHS " in
    *" $rel "*) ;;
    *) fail "$rel exists but is not registered in the manifest (classify it, e.g. kind=unit tier=local)" ;;
  esac
done

# ── No workflow run-line points at a harness path that no longer exists ─
# Scan non-comment lines of each workflow for ci/(e2e|check)-*.sh tokens.
for wf in "$WORKFLOWS"/*.yml "$WORKFLOWS"/*.yaml; do
  [ -f "$wf" ] || continue
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    [ -f "$ROOT/$p" ] || fail "$(basename "$wf") references a harness path that does not exist: $p"
  done <<EOF
$(grep -vE '^[[:space:]]*#' "$wf" | grep -oE 'ci/(e2e|check)-[a-z0-9-]+\.sh' | sort -u)
EOF
done

if [ "$FAIL" -eq 0 ]; then
  echo "OK: ci/harnesses.json is consistent with $((COUNT)) suites, the ci/ scripts, and the workflows."
  exit 0
fi
exit 1
