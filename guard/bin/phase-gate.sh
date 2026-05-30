#!/usr/bin/env bash
# phase-gate.sh — Universal sprint phase enforcement
# Blocks git commit/push when a sprint is active and required phases are incomplete.
# Called from check-dangerous.sh as Tier 2.75.
#
# Sprint detection (two methods, hard then soft):
#   1. session.json exists for this project with phases started → BLOCK on missing
#   2. Recent plan artifact exists but no session → WARN (advisory)
#
# Exit 0 = allow, Exit 1 = blocked
set -euo pipefail

CMD="${1:-}"

# Only intercept git commit and git push. The subcommand is recognized even when
# global options sit between `git` and it (`git -C . commit`,
# `git -c user.name='Jane Doe' commit`, with single- or double-quoted values),
# while commit/push must be a whole word so `git diff -- commit_helper.py` and
# `git grep commit` are not mistaken for a commit. Quoted spans are deliberately
# NOT stripped: a shell-executed commit such as `sh -c 'git commit -m x'` must
# still be gated. The trade-off is that a literal `git commit` inside a quoted
# argument of another command can be over-gated; for an enforcement gate, gating
# a non-commit is safer than letting a real commit skip the required phases.
#
# Backslash-escaped whitespace is a single shell token to git (`git -c
# user.name=Jane\ Doe commit`), so collapse it first or the option value would
# look like two tokens and the gate would miss the commit.
CMD_GATE=$(printf '%s' "$CMD" | sed 's/\\[[:space:]]/_/g')
if ! printf '%s' "$CMD_GATE" | grep -qE "(^|[^[:alnum:]_])git( +-[^ ]+( +([^ ]*('[^']*'|\"[^\"]*\"))*[^ ]*)?)* +(commit|push)([^[:alnum:]_]|\$)"; then
  exit 0
fi

# Explicit bypass
if [ "${NANOSTACK_SKIP_GATE:-}" = "1" ]; then
  exit 0
fi

# ─── Resolve paths ──────────────────────────────────────────
GUARD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NANOSTACK_ROOT="$(cd "$GUARD_DIR/.." && pwd)"
STORE_PATH_SH="$NANOSTACK_ROOT/bin/lib/store-path.sh"

[ -f "$STORE_PATH_SH" ] || exit 0
source "$STORE_PATH_SH"
PORTABLE_SH="$NANOSTACK_ROOT/bin/lib/portable.sh"
[ -f "$PORTABLE_SH" ] && source "$PORTABLE_SH"

# Mask inline secrets before the blocked command is written to the audit log.
REDACT_LIB="$NANOSTACK_ROOT/bin/lib/redact-secrets.sh"
if [ -f "$REDACT_LIB" ]; then
  # shellcheck disable=SC1090
  source "$REDACT_LIB"
else
  redact_secrets() { printf '%s' "${1:-}"; }
fi

FIND_ARTIFACT="$NANOSTACK_ROOT/bin/find-artifact.sh"
SESSION_SH="$NANOSTACK_ROOT/bin/session.sh"
SESSION_FILE="$NANOSTACK_STORE/session.json"
PROJECT="$(pwd)"

# Default required phases for the built-in sprint. The session's
# phase_graph (when present) overrides this with the actual ancestors
# of ship so a custom workflow stack gates on its own phases instead
# of the built-in trio. PR 4 of the 2026-05-10 architecture audit
# made the phase-gate graph-aware; Codex caught the gate-vs-can_ship
# drift on the eleventh review pass.
REQUIRED_PHASES="review security qa"
if [ -f "$SESSION_FILE" ] && command -v jq >/dev/null 2>&1; then
  # The session-level phase_graph is the source of truth when it
  # contains a `ship` node. We separate three cases:
  #   - graph absent             → legacy review/security/qa default
  #   - graph present + ship in  → graph-derived ancestors of ship
  #   - graph present + no ship  → legacy review/security/qa default
  #     (fail closed: the gate exists to protect ship-like actions, so
  #     a graph without ship cannot loosen the gate. Codex caught the
  #     ship-absent bypass on the PR 4 fourteenth review pass.)
  # The middle case may legitimately produce an empty array (a graph
  # like think -> plan -> build -> ship has no post-build gates), and
  # the gate honors that.
  if jq -e '(.phase_graph // []) | map(.name) | any(. == "ship")' "$SESSION_FILE" >/dev/null 2>&1; then
    REQUIRED_PHASES=$(jq -r '
      (.phase_graph // []) as $g
      | def ancestors($name):
          ($g | map(select(.name == $name)) | first // {depends_on:[]}).depends_on as $deps
          | $deps + ($deps | map(ancestors(.)) | add // []);
        (ancestors("ship")) as $ancs
        | [$g[].name
            | select(. as $n | $ancs | any(. == $n))
            | select(. != "think" and . != "plan" and . != "build")
          ]
        | join(" ")
    ' "$SESSION_FILE" 2>/dev/null)
  fi
fi

# ─── Reference timestamp: latest code change ────────────────
last_code_timestamp() {
  local ts
  ts=$(git log -1 --format=%ct 2>/dev/null || echo 0)
  if [ "$ts" -eq 0 ]; then
    # No commits yet: use newest source file mtime. Use nano_mtime so this
    # works on Linux too (the previous `xargs stat -f %m` was BSD-only and
    # silently returned 0 on Linux, neutering the phase gate).
    if declare -F nano_mtime >/dev/null 2>&1; then
      local newest=0 candidate
      while IFS= read -r f; do
        candidate=$(nano_mtime "$f")
        [ "$candidate" -gt "$newest" ] && newest="$candidate"
      done < <(find . -maxdepth 3 \( -name '*.js' -o -name '*.ts' -o -name '*.py' -o -name '*.go' -o -name '*.html' -o -name '*.css' -o -name '*.sh' \) 2>/dev/null | head -20)
      ts="$newest"
    else
      # Fallback: try BSD stat then GNU stat in one go.
      ts=$(find . -maxdepth 3 \( -name '*.js' -o -name '*.ts' -o -name '*.py' -o -name '*.go' -o -name '*.html' -o -name '*.css' -o -name '*.sh' \) 2>/dev/null \
        | head -20 | xargs stat -f %m 2>/dev/null | sort -rn | head -1)
      [ -z "$ts" ] && ts=$(find . -maxdepth 3 \( -name '*.js' -o -name '*.ts' -o -name '*.py' -o -name '*.go' -o -name '*.html' -o -name '*.css' -o -name '*.sh' \) 2>/dev/null \
        | head -20 | xargs stat -c %Y 2>/dev/null | sort -rn | head -1)
      [ -z "$ts" ] && ts=0
    fi
  fi
  echo "$ts"
}

# ─── Check if required phase artifacts are fresh ────────────
# Returns space-separated list of missing phases
check_phases() {
  local last_change="$1"
  local missing=""

  for phase in $REQUIRED_PHASES; do
    local artifact
    # PR 3 of the 2026-05-28 architecture follow-up: the gate consumes
    # TRUSTED artifacts. --require-integrity makes find-artifact.sh exit
    # non-zero when the phase artifact is absent, has no .integrity, or
    # whose recomputed hash does not match, so integrity_missing and
    # integrity_mismatch are treated exactly like missing evidence here.
    artifact=$("$FIND_ARTIFACT" "$phase" 1 --require-integrity 2>/dev/null) || {
      missing="${missing:+$missing }$phase"
      continue
    }
    # Verify artifact belongs to this project
    if ! jq -e --arg p "$PROJECT" '.project == $p' "$artifact" >/dev/null 2>&1; then
      missing="${missing:+$missing }$phase"
      continue
    fi
    # Freshness by FILENAME timestamp, not mtime. save-artifact.sh names
    # artifacts $(date -u +%Y%m%d-%H%M%S).json, so the timestamp travels
    # with the filename. A copied or `touch`-ed stale artifact keeps its
    # old filename timestamp even when its mtime is fresh, so it cannot
    # pass the freshness check by touching the file. nano_artifact_filename_epoch
    # returns 0 for an unparseable name, which reads as "older than the
    # last code change" and fails the phase closed.
    local artifact_time=0
    if declare -F nano_artifact_filename_epoch >/dev/null 2>&1; then
      artifact_time=$(nano_artifact_filename_epoch "$artifact")
    fi
    if [ "$artifact_time" -lt "$last_change" ]; then
      missing="${missing:+$missing }$phase"
    fi
  done

  echo "$missing"
}

# ─── Print block message ───────────────────────────────────
print_block() {
  local missing="$1"
  echo "BLOCKED [PHASE-GATE] Sprint phases incomplete: $(echo "$missing" | tr ' ' ', ')"
  echo "Category: sprint-pipeline"
  echo ""
  echo "Action: complete these phases before committing:"
  for phase in $missing; do
    case "$phase" in
      review)   echo "  /review   — Code review" ;;
      security) echo "  /security — Security audit" ;;
      qa)       echo "  /qa       — Testing" ;;
      # PR 4 of the 2026-05-10 audit made the gate graph-aware, so the
      # missing list can include custom phases (license-audit, etc).
      # The default case keeps the remediation actionable for those
      # users instead of printing a blank section. Codex caught the
      # empty-section regression on the fifteenth review pass.
      *)        echo "  /$phase — custom workflow phase (run its skill)" ;;
    esac
  done
  echo ""
  echo "Bypass: NANOSTACK_SKIP_GATE=1 git commit ...   (non-sprint commits only)"
}

print_warning() {
  local missing="$1"
  echo "WARNING [PHASE-GATE] Sprint detected but phases incomplete: $(echo "$missing" | tr ' ' ', ')"
  echo ""
  echo "A plan artifact exists for this project. Consider running:"
  for phase in $missing; do
    case "$phase" in
      review)   echo "  /review   — Code review" ;;
      security) echo "  /security — Security audit" ;;
      qa)       echo "  /qa       — Testing" ;;
      *)        echo "  /$phase — custom workflow phase (run its skill)" ;;
    esac
  done
  echo ""
  echo "Proceeding anyway (no active session). Use /feature or /think --autopilot for enforced sprints."
}

# ─── Method 1: Session-based detection (hard enforcement) ───
if [ -f "$SESSION_FILE" ]; then
  SESSION_PROJECT=$(jq -r '.workspace // ""' "$SESSION_FILE" 2>/dev/null)

  if [ "$SESSION_PROJECT" = "$PROJECT" ]; then
    # Skip if sprint is already shipped (completed)
    SHIP_DONE=$(jq -r '[.phase_log[] | select(.phase == "ship" and .status == "completed")] | length' "$SESSION_FILE" 2>/dev/null || echo "0")
    if [ "$SHIP_DONE" -gt 0 ]; then
      exit 0
    fi

    # Skip if no phases have started (session just initialized). The
    # filter excludes synthetic entries (source: "feature-skip" or
    # similar markers) so a /feature session that pre-seeded think as
    # completed at init does not activate the gate before /plan runs.
    # Codex caught the premature-block regression on the PR 4
    # thirteenth review pass.
    PHASES_STARTED=$(jq -r '
      [.phase_log[]? | select((.source // "") | startswith("feature-skip") | not)] | length
    ' "$SESSION_FILE" 2>/dev/null || echo "0")
    if [ "$PHASES_STARTED" -eq 0 ]; then
      exit 0
    fi

    # Active sprint — enforce
    LAST_CHANGE=$(last_code_timestamp)
    MISSING=$(check_phases "$LAST_CHANGE")

    if [ -n "$MISSING" ]; then
      print_block "$MISSING"

      # Audit (the command is redacted so an inline secret is not persisted)
      if [ -d "$(dirname "$NANOSTACK_STORE/audit.log")" ]; then
        echo "{\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"phase-gate-block\",\"missing\":\"$MISSING\",\"cmd\":$(redact_secrets "$CMD" | jq -Rs .)}" >> "$NANOSTACK_STORE/audit.log" 2>/dev/null || true
      fi

      exit 1
    fi

    # All phases complete
    exit 0
  fi
fi

# ─── Method 2: Artifact-based detection (soft enforcement) ──
if [ -x "$FIND_ARTIFACT" ]; then
  PLAN_ARTIFACT=$("$FIND_ARTIFACT" plan 1 2>/dev/null) || true

  if [ -n "$PLAN_ARTIFACT" ]; then
    PLAN_PROJECT=$(jq -r '.project // ""' "$PLAN_ARTIFACT" 2>/dev/null)

    if [ "$PLAN_PROJECT" = "$PROJECT" ]; then
      LAST_CHANGE=$(last_code_timestamp)
      MISSING=$(check_phases "$LAST_CHANGE")

      if [ -n "$MISSING" ]; then
        # Soft enforcement: warn but allow
        print_warning "$MISSING"
        exit 0
      fi
    fi
  fi
fi

# No sprint detected
exit 0
