#!/usr/bin/env bash
# resolve.sh — Centralized context resolver for nanostack skills
# Replaces per-skill Step 0 boilerplate with a single call.
# Routes context based on phase: loads upstream artifacts, matched solutions,
# conflict precedents, diarizations, and config.
#
# Usage: resolve.sh <phase> [--diff] [--skip-solutions] [--max-age <phase>:<days>]...
#   phase: plan, review, security, qa, ship, compound, feature
#   --diff:                match solutions against current git diff file paths
#   --skip-solutions:      do not load solutions (for fast/CI runs)
#   --max-age <phase>:<n>: override per-phase upstream artifact age window in days
#                          (e.g., --max-age plan:5 --max-age think:30). Repeatable.
#
# Output: JSON blob with all resolved context paths and summaries.
# Exit 0 on success (even if some lookups return empty).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
[ -f "$SCRIPT_DIR/lib/preflight.sh" ] && { source "$SCRIPT_DIR/lib/preflight.sh"; nanostack_require jq; }
[ -f "$SCRIPT_DIR/lib/cache.sh" ] && source "$SCRIPT_DIR/lib/cache.sh"
. "$SCRIPT_DIR/lib/phases.sh"
[ -f "$SCRIPT_DIR/lib/artifact-trust.sh" ] && . "$SCRIPT_DIR/lib/artifact-trust.sh"

# Portable timeout wrapper: gtimeout (coreutils on macOS) → timeout (Linux) → run as-is.
# Used to bound expensive solution lookups so resolve.sh never hangs the sprint.
_nano_timeout() {
  local secs="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

PHASE="${1:?Usage: resolve.sh <phase> [--diff] [--skip-solutions] [--max-age <phase>:<days>]...}"
shift
USE_DIFF=false
SKIP_SOLUTIONS_FLAG=false
MAX_AGE_OVERRIDES=""  # space-separated "phase:days" pairs from --max-age flags

while [ $# -gt 0 ]; do
  case "$1" in
    --diff) USE_DIFF=true; shift ;;
    --skip-solutions) SKIP_SOLUTIONS_FLAG=true; shift ;;
    --max-age)
      if [ -n "${2:-}" ]; then
        MAX_AGE_OVERRIDES="${MAX_AGE_OVERRIDES:+$MAX_AGE_OVERRIDES }$2"
        shift 2
      else
        echo "ERROR: --max-age requires <phase>:<days> argument" >&2
        exit 2
      fi
      ;;
    *) shift ;;  # unknown flag: ignore (forward compatibility)
  esac
done

# ─── Routing table ─────────────────────────────────────────
# Which upstream artifacts and solutions each phase needs.
# This is the only place routing logic lives.

UPSTREAM=""  # space-separated "phase:age" pairs (age in days, default 2)
LOAD_SOLUTIONS=false
SOLUTION_STRATEGY=""  # keywords, files, both
LOAD_PRECEDENTS=false
LOAD_DIARIZATIONS=false
PHASE_KIND="core"

case "$PHASE" in
  plan)
    UPSTREAM="think:2"
    LOAD_SOLUTIONS=true
    SOLUTION_STRATEGY="keywords"
    ;;
  review)
    UPSTREAM="plan:2"
    LOAD_SOLUTIONS=true
    SOLUTION_STRATEGY="files"
    LOAD_PRECEDENTS=true
    LOAD_DIARIZATIONS=true
    ;;
  security)
    UPSTREAM="plan:2 review:30"
    LOAD_SOLUTIONS=true
    SOLUTION_STRATEGY="files"
    LOAD_PRECEDENTS=true
    LOAD_DIARIZATIONS=true
    ;;
  qa)
    UPSTREAM="plan:2"
    LOAD_DIARIZATIONS=true
    ;;
  ship)
    UPSTREAM="review:2 security:2 qa:2"
    ;;
  compound)
    UPSTREAM="think:2 plan:2 review:2 security:2 qa:2 ship:2"
    ;;
  feature)
    UPSTREAM="think:30 plan:30 ship:30"
    LOAD_SOLUTIONS=true
    SOLUTION_STRATEGY="keywords"
    ;;
  *)
    # Custom-phase fallback. A phase that's registered in
    # .nanostack/config.json (custom_phases) returns minimal context:
    # upstream artifacts driven by phase_graph or skill frontmatter,
    # plus the optional context routing block (phase_context) added in
    # PR 5 of the 2026-05-10 architecture audit. An unregistered phase
    # still exits 1 so set -e callers fail closed.
    if [ "$(nano_phase_kind "$PHASE" 2>/dev/null)" = "custom" ]; then
      PHASE_KIND="custom"
      DEPS=""
      GRAPH_LISTED_PHASE=false
      # First source: phase_graph from config (already validated by
      # bin/lib/phases.sh; invalid graphs already fell back to default).
      # An entry with depends_on=[] is a deliberate "no dependencies"
      # declaration, distinct from the phase not being in the graph at
      # all — so we track presence separately and only fall back to
      # SKILL.md when the phase is absent from the graph.
      GRAPH=$(nano_phase_graph_json 2>/dev/null || echo "")
      if [ -n "$GRAPH" ] && echo "$GRAPH" | jq -e --arg p "$PHASE" 'any(.[]; .name == $p)' >/dev/null 2>&1; then
        GRAPH_LISTED_PHASE=true
        DEPS=$(echo "$GRAPH" | jq -r --arg p "$PHASE" '.[] | select(.name == $p) | .depends_on[]?' 2>/dev/null | tr '\n' ' ')
      fi
      # Second source: SKILL.md frontmatter `depends_on` field, only if
      # the phase is absent from phase_graph. Supports inline list form
      # `depends_on: [build, ship]` and block list form
      # (`depends_on:\n  - build`).
      if [ "$GRAPH_LISTED_PHASE" = false ]; then
        SKILL_DIR=$(nano_phase_skill_path "$PHASE" 2>/dev/null) || SKILL_DIR=""
        if [ -n "$SKILL_DIR" ] && [ -f "$SKILL_DIR/SKILL.md" ]; then
          DEPS=$(awk '
            /^---[[:space:]]*$/ { f=!f; next }
            f && /^depends_on:/ {
              # Strip "depends_on:" prefix.
              sub(/^depends_on:[[:space:]]*/, "")
              # Inline list: [a, b, c]
              if ($0 ~ /^\[/) {
                gsub(/[][,]/, " ")
                print
                next
              }
              # Empty value: block list follows or no deps at all.
              if (length($0) == 0) {
                block_mode = 1
                next
              }
            }
            f && block_mode && /^[[:space:]]*-[[:space:]]*/ {
              sub(/^[[:space:]]*-[[:space:]]*/, "")
              print
              next
            }
            f && block_mode && /^[^[:space:]-]/ { block_mode = 0 }
          ' "$SKILL_DIR/SKILL.md" | tr '\n' ' ')
        fi
      fi
      # Build UPSTREAM list. Skip the conductor's "build" stage — it has
      # no artifact directory, so we keep the dep visible to graph
      # consumers but never look up a file for it. Default age 30 days
      # (custom phases are typically less time-sensitive than core).
      for d in $DEPS; do
        d=$(printf '%s' "$d" | tr -d '[:space:]')
        [ -z "$d" ] && continue
        if [ "$d" = "build" ]; then
          # Recorded so the output keeps the dep, but find-artifact
          # below will never produce a hit for build.
          UPSTREAM="${UPSTREAM:+$UPSTREAM }build:0"
          continue
        fi
        UPSTREAM="${UPSTREAM:+$UPSTREAM }$d:30"
      done
    else
      echo "{\"error\": \"unknown phase: $PHASE\"}" >&2
      exit 1
    fi
    ;;
esac

# ─── Custom routing contract (PR 5 of architecture vNext) ──────
# Custom skills can declare a `phase_context` block in
# .nanostack/config.json that tells the resolver what shape of
# context they need: which upstreams are required vs optional, what
# trust level (strict / normal) gates the artifact loads, a per-
# phase max_age override, plus solution_tags and diarization_paths
# to widen the lookup beyond dependency edges. Core phases ignore
# this block; their routing stays hardcoded in the case statement
# above. Custom phases with no phase_context entry keep their pre-
# PR-5 behavior (upstreams from deps, no solutions / diarizations).
ROUTING_TRUST="normal"
ROUTING_REQUIRED_JSON="[]"
ROUTING_OPTIONAL_JSON="[]"
ROUTING_MAX_AGE_DAYS=""
ROUTING_SOLUTION_TAGS_JSON="[]"
ROUTING_SOLUTION_LIMIT=""
ROUTING_DIARIZATION_PATHS_JSON="[]"
ROUTING_DIARIZATION_KEYWORDS_JSON="[]"
ROUTING_DECLARED=false
if [ "$PHASE_KIND" = "custom" ]; then
  # Resolve the same config the phase registry used: prefer the
  # project-local .nanostack/config.json, fall back to the global
  # ~/.nanostack/config.json so a user-level routing entry still
  # applies to a project that has no local config. Codex caught
  # the missed-fallback regression on the PR 5 second review pass.
  ROUTING_CFG=""
  if declare -F _nano_phases_resolve_config >/dev/null 2>&1; then
    ROUTING_CFG=$(_nano_phases_resolve_config 2>/dev/null || echo "")
  fi
  [ -z "$ROUTING_CFG" ] && ROUTING_CFG="$NANOSTACK_STORE/config.json"
  if [ -f "$ROUTING_CFG" ] && command -v jq >/dev/null 2>&1; then
    if jq -e --arg p "$PHASE" '.phase_context // {} | has($p)' "$ROUTING_CFG" >/dev/null 2>&1; then
      ROUTING_DECLARED=true
      ROUTING_TRUST=$(jq -r --arg p "$PHASE" '.phase_context[$p].trust // "normal"' "$ROUTING_CFG" 2>/dev/null)
      ROUTING_REQUIRED_JSON=$(jq -c --arg p "$PHASE" '.phase_context[$p].upstream_required // []' "$ROUTING_CFG" 2>/dev/null)
      ROUTING_OPTIONAL_JSON=$(jq -c --arg p "$PHASE" '.phase_context[$p].upstream_optional // []' "$ROUTING_CFG" 2>/dev/null)
      ROUTING_MAX_AGE_DAYS=$(jq -r --arg p "$PHASE" '.phase_context[$p].max_age_days // ""' "$ROUTING_CFG" 2>/dev/null)
      ROUTING_SOLUTION_TAGS_JSON=$(jq -c --arg p "$PHASE" '.phase_context[$p].solutions.tags // []' "$ROUTING_CFG" 2>/dev/null)
      ROUTING_SOLUTION_LIMIT=$(jq -r --arg p "$PHASE" '.phase_context[$p].solutions.limit // ""' "$ROUTING_CFG" 2>/dev/null)
      ROUTING_DIARIZATION_PATHS_JSON=$(jq -c --arg p "$PHASE" '.phase_context[$p].diarizations.paths // []' "$ROUTING_CFG" 2>/dev/null)
      ROUTING_DIARIZATION_KEYWORDS_JSON=$(jq -c --arg p "$PHASE" '.phase_context[$p].diarizations.keywords // []' "$ROUTING_CFG" 2>/dev/null)
      case "$ROUTING_TRUST" in
        strict|normal) ;;
        *) ROUTING_TRUST="normal" ;;
      esac

      # Routed upstreams that are not already in the dependency-derived
      # UPSTREAM list still need their artifacts resolved so consumers
      # see status + paths. Codex caught the missing wiring on the
      # PR 5 first review pass: declaring upstream_optional: ["security"]
      # without listing security in depends_on left it absent from
      # upstream_status entirely. Default age for the merge follows the
      # routing max_age_days when set, otherwise the per-phase 30-day
      # custom default.
      _routed_default_age=30
      [ -n "$ROUTING_MAX_AGE_DAYS" ] && [ "$ROUTING_MAX_AGE_DAYS" != "null" ] && _routed_default_age="$ROUTING_MAX_AGE_DAYS"
      _add_routed_upstream() {
        local extra="$1"
        [ -z "$extra" ] && return 0
        case " $UPSTREAM " in
          *" ${extra}:"*) return 0 ;;
        esac
        if [ "$extra" = "build" ]; then
          UPSTREAM="${UPSTREAM:+$UPSTREAM }build:0"
        else
          UPSTREAM="${UPSTREAM:+$UPSTREAM }$extra:$_routed_default_age"
        fi
      }
      while IFS= read -r r; do
        [ -z "$r" ] || [ "$r" = "null" ] && continue
        _add_routed_upstream "$r"
      done < <(echo "$ROUTING_REQUIRED_JSON" | jq -r '.[]?' 2>/dev/null)
      while IFS= read -r r; do
        [ -z "$r" ] || [ "$r" = "null" ] && continue
        _add_routed_upstream "$r"
      done < <(echo "$ROUTING_OPTIONAL_JSON" | jq -r '.[]?' 2>/dev/null)
      unset -f _add_routed_upstream
    fi
  fi
fi

# ─── 1. Resolve upstream artifacts ─────────────────────────
#
# upstream_artifacts keeps its historical shape: only verified paths
# appear (the --verify call drops integrity-mismatched files). New in
# the 2026-05-10 architecture audit (PR 2): upstream_status exposes
# the trust state for every declared upstream so downstream consumers
# can distinguish "no artifact" from "tampered" from "missing
# integrity field" without reimplementing the check. release-readiness
# and other release gates can switch to --require-integrity in their
# own find-artifact.sh calls when they need strict semantics.
#
# PR 5 of the architecture audit adds the phase_context routing
# block: strict trust upgrades artifact-loading to --require-integrity
# (rejects integrity_missing in addition to mismatch) and max_age_days
# overrides the per-phase age. upstream_required + upstream_optional
# from the routing block surface in the routing.required / optional
# lists for downstream consumers; missing-from-store required entries
# already report status=missing.

ARTIFACTS_JSON="{"
STATUS_JSON="{"
FIRST=true
SFIRST=true
for entry in $UPSTREAM; do
  phase="${entry%%:*}"
  age="${entry#*:}"
  [ "$age" = "$entry" ] && age=2  # default if no colon
  # Apply --max-age override if one matches this phase
  for override in $MAX_AGE_OVERRIDES; do
    o_phase="${override%%:*}"
    o_age="${override#*:}"
    if [ "$o_phase" = "$phase" ] && [ -n "$o_age" ] && [ "$o_age" != "$override" ]; then
      age="$o_age"
    fi
  done
  # Phase context max_age_days overrides per-phase default. CLI
  # --max-age stays on top so an operator can widen the window for a
  # specific run without editing config.
  if [ -n "$ROUTING_MAX_AGE_DAYS" ] && [ "$ROUTING_MAX_AGE_DAYS" != "null" ]; then
    age="$ROUTING_MAX_AGE_DAYS"
    for override in $MAX_AGE_OVERRIDES; do
      o_phase="${override%%:*}"
      o_age="${override#*:}"
      if [ "$o_phase" = "$phase" ] && [ -n "$o_age" ] && [ "$o_age" != "$override" ]; then
        age="$o_age"
      fi
    done
  fi

  # Look up the latest artifact for this phase WITHOUT --verify so we
  # can classify it ourselves via nano_artifact_trust. The verified
  # variant below decides what goes into upstream_artifacts.
  RAW=$("$SCRIPT_DIR/find-artifact.sh" "$phase" "$age" 2>/dev/null) || RAW=""

  STATUS="missing"
  if [ -n "$RAW" ]; then
    if declare -F nano_artifact_trust >/dev/null 2>&1; then
      # Keep `||` OUTSIDE the command substitution so a deletion race
      # (file vanishes between find-artifact.sh and nano_artifact_trust)
      # cleanly maps to "missing" instead of leaving "not_found" plus a
      # trailing "missing" inside STATUS. Codex caught this on the PR 2
      # review: the previous inline `|| echo "missing"` produced a
      # literal newline that broke jq --argjson upstream_status.
      STATUS=$(nano_artifact_trust "$RAW" 2>/dev/null) || STATUS="missing"
      # Defense in depth: normalize any unexpected helper output (empty
      # string, not_found leaking through, future statuses) to one of
      # the four contract values so the JSON shape stays stable.
      case "$STATUS" in
        verified|integrity_missing|integrity_mismatch) ;;
        *) STATUS="missing" ;;
      esac
    else
      STATUS="verified"  # helper unavailable; assume verified to keep legacy behavior
    fi
  fi

  # upstream_artifacts: only include verified artifacts so a tampered
  # file in the store cannot drive downstream context. integrity_missing
  # artifacts also load so legacy stores (saved before integrity was
  # added) continue to work; release gates that need strict semantics
  # call find-artifact.sh --require-integrity themselves and read
  # upstream_status for the explicit signal.
  #
  # PR 5: phase_context.trust = strict rejects integrity_missing too,
  # so a custom skill that declared strict trust never sees a path it
  # cannot verify. Normal trust keeps the historical lenient behavior
  # (legacy artifacts saved before .integrity was added still load).
  ALLOWED_STATUSES="verified|integrity_missing"
  if [ "$ROUTING_TRUST" = "strict" ]; then
    ALLOWED_STATUSES="verified"
  fi
  case "$STATUS" in
    verified|integrity_missing)
      if [ "$ROUTING_TRUST" = "strict" ] && [ "$STATUS" != "verified" ]; then
        if [ "$PHASE_KIND" = "custom" ]; then
          $FIRST || ARTIFACTS_JSON="$ARTIFACTS_JSON,"
          ARTIFACTS_JSON="$ARTIFACTS_JSON\"$phase\":null"
          FIRST=false
        fi
      else
        $FIRST || ARTIFACTS_JSON="$ARTIFACTS_JSON,"
        ARTIFACTS_JSON="$ARTIFACTS_JSON\"$phase\":\"$RAW\""
        FIRST=false
      fi
      ;;
    *)
      if [ "$PHASE_KIND" = "custom" ]; then
        # Custom phases keep declared-but-missing deps in the output
        # as `null` so consumers can tell "we asked for this and found
        # nothing" apart from "this was never a dep". Core phases keep
        # the historical "omit if missing" behavior to avoid changing
        # the JSON shape for downstream skills.
        $FIRST || ARTIFACTS_JSON="$ARTIFACTS_JSON,"
        ARTIFACTS_JSON="$ARTIFACTS_JSON\"$phase\":null"
        FIRST=false
      fi
      ;;
  esac

  # upstream_status: always include every declared upstream so callers
  # can read a single key to know the trust state. Possible values:
  # verified, integrity_missing, integrity_mismatch, missing. build is
  # the conductor's no-artifact stage; record it as not_applicable.
  if [ "$phase" = "build" ]; then
    STATUS="not_applicable"
  fi
  $SFIRST || STATUS_JSON="$STATUS_JSON,"
  STATUS_JSON="$STATUS_JSON\"$phase\":\"$STATUS\""
  SFIRST=false
done
ARTIFACTS_JSON="$ARTIFACTS_JSON}"
STATUS_JSON="$STATUS_JSON}"

# ─── 2. Resolve solutions ──────────────────────────────────

SOLUTIONS_JSON="[]"

# PR 5: when a custom phase declares solution_tags in phase_context,
# load matching solutions even though the core LOAD_SOLUTIONS flag is
# false for custom phases. Tag matching is case-insensitive substring
# over each solution's frontmatter tags field and its filename so a
# skill author does not need to invent a new index.
if [ "$SKIP_SOLUTIONS_FLAG" = false ] && [ "$PHASE_KIND" = "custom" ] \
   && [ "$ROUTING_SOLUTION_TAGS_JSON" != "[]" ] \
   && [ -d "$NANOSTACK_STORE/know-how/solutions" ]; then
  custom_limit="${ROUTING_SOLUTION_LIMIT:-10}"
  [ -z "$custom_limit" ] || [ "$custom_limit" = "null" ] && custom_limit=10
  tag_matches=""
  while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    while IFS= read -r sol; do
      [ -z "$sol" ] && continue
      tag_matches="${tag_matches}${sol}
"
    done < <(grep -lriF -- "$tag" "$NANOSTACK_STORE/know-how/solutions" 2>/dev/null | head -"$custom_limit")
  done < <(echo "$ROUTING_SOLUTION_TAGS_JSON" | jq -r '.[]?' 2>/dev/null)
  if [ -n "$tag_matches" ]; then
    SOLUTIONS_JSON=$(echo "$tag_matches" | sed '/^$/d' | sort -u | head -"$custom_limit" | jq -R . | jq -sc '.')
  fi
fi

if [ "$LOAD_SOLUTIONS" = true ] && [ "$SKIP_SOLUTIONS_FLAG" = false ]; then
  DIFF_FILES=""
  if [ "$USE_DIFF" = true ]; then
    # Cache the diff keyed on HEAD rev so multiple resolve.sh invocations in
    # the same sprint reuse one git call. New commits invalidate via the key.
    DIFF_CACHE=""
    if declare -F nano_cache_dir >/dev/null 2>&1; then
      HEAD_REV=$(git rev-parse --short HEAD 2>/dev/null || echo "no-head")
      DIFF_CACHE="$(nano_cache_dir)/git-diff-${HEAD_REV}"
    fi
    if [ -n "$DIFF_CACHE" ] && nano_cache_fresh "$DIFF_CACHE" 30 2>/dev/null; then
      DIFF_FILES=$(cat "$DIFF_CACHE")
    else
      DIFF_FILES=$(git diff --name-only HEAD 2>/dev/null || git diff --name-only 2>/dev/null || echo "")
      STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
      [ -n "$STAGED" ] && DIFF_FILES="$DIFF_FILES
$STAGED"
      DIFF_FILES=$(echo "$DIFF_FILES" | sort -u | head -20)
      [ -n "$DIFF_CACHE" ] && printf '%s\n' "$DIFF_FILES" > "$DIFF_CACHE" 2>/dev/null || true
    fi
  fi

  SOLUTION_OUTPUT=""
  case "$SOLUTION_STRATEGY" in
    files)
      if [ -n "$DIFF_FILES" ]; then
        # Search by each changed file path (take top 5 unique dirs)
        DIRS=$(echo "$DIFF_FILES" | xargs -I{} dirname {} 2>/dev/null | sort -u | head -5)
        for dir in $DIRS; do
          # Bound find-solution at 3s; on timeout/failure fall back to a direct
          # listing of files under that dir so the model still sees candidates.
          RESULT=$(_nano_timeout 3 "$SCRIPT_DIR/find-solution.sh" --file "$dir" 2>/dev/null || true)
          if [ -z "$RESULT" ] && [ -d "$NANOSTACK_STORE/know-how/solutions" ]; then
            RESULT=$(find "$NANOSTACK_STORE/know-how/solutions" -name "*.md" -type f -path "*${dir}*" 2>/dev/null | head -5)
          fi
          [ -n "$RESULT" ] && SOLUTION_OUTPUT="$SOLUTION_OUTPUT
$RESULT"
        done
      fi
      ;;
    keywords)
      # Keywords mode: list all available solutions so the model can pick relevant ones.
      # find-solution.sh requires a query, so we list files directly.
      if [ -d "$NANOSTACK_STORE/know-how/solutions" ]; then
        SOLUTION_OUTPUT=$(find "$NANOSTACK_STORE/know-how/solutions" -name "*.md" -type f 2>/dev/null | sort -r | head -10)
      fi
      ;;
  esac

  # Parse solution output into JSON
  if [ -n "$SOLUTION_OUTPUT" ]; then
    # Extract unique file paths from the find-solution.sh output
    # find-solution.sh --full returns bare paths; summary mode has paths in brackets
    PATHS=$(echo "$SOLUTION_OUTPUT" | grep -E '^\s*\[' | sed 's/.*] //' | sed 's/ (.*//' 2>/dev/null || echo "")
    if [ -z "$PATHS" ]; then
      # --full mode output: bare file paths
      PATHS=$(echo "$SOLUTION_OUTPUT" | grep '\.md$' | head -10)
    fi

    if [ -n "$PATHS" ]; then
      SOLUTIONS_JSON=$(echo "$PATHS" | head -10 | sed '/^$/d' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s '.')
    fi
  fi
fi

# ─── 3. Resolve conflict precedents ────────────────────────

PRECEDENTS_JSON="null"
if [ "$LOAD_PRECEDENTS" = true ]; then
  PREC_FILE="$SCRIPT_DIR/../reference/conflict-precedents.md"
  if [ -f "$PREC_FILE" ]; then
    PRECEDENTS_JSON="\"$PREC_FILE\""
  fi
fi

# ─── 4. Resolve diarizations ───────────────────────────────

DIARIZATIONS_JSON="[]"
# PR 5: a custom phase can declare diarization paths or keywords in
# phase_context to load diarizations by topic instead of git diff. A
# diarization matches when its `subject:` line contains any of the
# declared paths or keywords (case-insensitive substring). This
# parallels the core LOAD_DIARIZATIONS path but does not require a
# diff to be present.
if [ "$PHASE_KIND" = "custom" ] \
   && { [ "$ROUTING_DIARIZATION_PATHS_JSON" != "[]" ] || [ "$ROUTING_DIARIZATION_KEYWORDS_JSON" != "[]" ]; }; then
  DIARIZE_DIR="$NANOSTACK_STORE/know-how/diarizations"
  if [ -d "$DIARIZE_DIR" ]; then
    needles=""
    while IFS= read -r needle; do
      [ -z "$needle" ] && continue
      needles="${needles}${needle}
"
    done < <(echo "$ROUTING_DIARIZATION_PATHS_JSON $ROUTING_DIARIZATION_KEYWORDS_JSON" | jq -r '.[]?' 2>/dev/null)
    if [ -n "$needles" ]; then
      # Build the diarizations array through jq so quotes, backslashes
      # or other JSON metacharacters in a subject or path do not break
      # the final --argjson parse. Codex caught the string-concat
      # injection on the PR 5 third review pass.
      DIARIZATIONS_JSON='[]'
      for dfile in "$DIARIZE_DIR"/*.md; do
        [ -f "$dfile" ] || continue
        SUBJECT=$(sed -n '/^---$/,/^---$/p' "$dfile" | grep -i '^subject:' | head -1 | sed 's/^subject: *//i')
        [ -z "$SUBJECT" ] && continue
        matched=false
        while IFS= read -r needle; do
          [ -z "$needle" ] && continue
          # -F: literal substring, not regex. Codex caught the regex
          # interpretation on the PR 5 second review pass: a path like
          # app/users/[id]/page.tsx would match unrelated subjects
          # such as app/users/i/page.tsx because [id] read as a class.
          if printf '%s' "$SUBJECT" | grep -qiF -- "$needle" 2>/dev/null; then
            matched=true
            break
          fi
        done <<< "$needles"
        if [ "$matched" = true ]; then
          FILE_DATE=$(sed -n '/^---$/,/^---$/p' "$dfile" | grep -i '^date:' | head -1 | sed 's/^date: *//i')
          AGE_DAYS="unknown"
          if [ -n "$FILE_DATE" ]; then
            if command -v gdate >/dev/null 2>&1; then DC="gdate"; else DC="date"; fi
            FILE_EPOCH=$($DC -d "$FILE_DATE" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$($DC +%s 2>/dev/null || echo 0)
            if [ "$FILE_EPOCH" -gt 0 ]; then
              AGE_DAYS=$(( (NOW_EPOCH - FILE_EPOCH) / 86400 ))
            fi
          fi
          DIARIZATIONS_JSON=$(echo "$DIARIZATIONS_JSON" | jq \
            --arg path "$dfile" \
            --arg subject "$SUBJECT" \
            --arg age_days "$AGE_DAYS" \
            '. + [{path: $path, subject: $subject, age_days: $age_days}]')
        fi
      done
    fi
  fi
fi

if [ "$LOAD_DIARIZATIONS" = true ] && [ "$DIARIZATIONS_JSON" = "[]" ]; then
  DIARIZE_DIR="$NANOSTACK_STORE/know-how/diarizations"
  if [ -d "$DIARIZE_DIR" ] && [ "$USE_DIFF" = true ] && [ -n "$DIFF_FILES" ]; then
    DIAR_RESULTS="["
    DFIRST=true
    for dfile in "$DIARIZE_DIR"/*.md; do
      [ -f "$dfile" ] || continue
      # Extract subject from frontmatter
      SUBJECT=$(sed -n '/^---$/,/^---$/p' "$dfile" | grep -i '^subject:' | head -1 | sed 's/^subject: *//i')
      [ -z "$SUBJECT" ] && continue

      # Check if any changed file overlaps with the diarization subject
      if echo "$DIFF_FILES" | grep -qi "$SUBJECT" 2>/dev/null; then
        # Calculate age in days
        FILE_DATE=$(sed -n '/^---$/,/^---$/p' "$dfile" | grep -i '^date:' | head -1 | sed 's/^date: *//i')
        AGE_DAYS="unknown"
        if [ -n "$FILE_DATE" ]; then
          if command -v gdate >/dev/null 2>&1; then DC="gdate"; else DC="date"; fi
          FILE_EPOCH=$($DC -d "$FILE_DATE" +%s 2>/dev/null || echo 0)
          NOW_EPOCH=$($DC +%s 2>/dev/null || echo 0)
          if [ "$FILE_EPOCH" -gt 0 ]; then
            AGE_DAYS=$(( (NOW_EPOCH - FILE_EPOCH) / 86400 ))
          fi
        fi

        $DFIRST || DIAR_RESULTS="$DIAR_RESULTS,"
        DIAR_RESULTS="$DIAR_RESULTS{\"path\":\"$dfile\",\"subject\":\"$SUBJECT\",\"age_days\":\"$AGE_DAYS\"}"
        DFIRST=false
      fi
    done
    DIARIZATIONS_JSON="$DIAR_RESULTS]"
  fi
fi

# ─── 5. Load config ────────────────────────────────────────

CONFIG_JSON="{}"
CONFIG_FILE="$NANOSTACK_STORE/config.json"
if [ -f "$CONFIG_FILE" ]; then
  CONFIG_JSON=$(jq -c '{
    intensity: (.preferences.default_intensity // "standard"),
    conflict_precedence: (.preferences.conflict_precedence // "security"),
    detected_stack: (.detected // [])
  }' "$CONFIG_FILE" 2>/dev/null) || CONFIG_JSON="{}"
fi

# ─── 6. Load goal from session ─────────────────────────────

GOAL="null"
SESSION_FILE="$NANOSTACK_STORE/session.json"
if [ -f "$SESSION_FILE" ]; then
  SESSION_GOAL=$(jq -r '.goal // ""' "$SESSION_FILE" 2>/dev/null)
  [ -n "$SESSION_GOAL" ] && GOAL="\"$SESSION_GOAL\""
fi

# ─── 7. Load sprint metrics (plan + compound phases) ───────

METRICS_JSON="null"
if [ "$PHASE" = "plan" ] || [ "$PHASE" = "compound" ]; then
  METRICS_SH="$SCRIPT_DIR/sprint-metrics.sh"
  if [ -x "$METRICS_SH" ]; then
    METRICS_JSON=$("$METRICS_SH" 2>/dev/null) || METRICS_JSON="null"
  fi
fi

# ─── Output ─────────────────────────────────────────────────

# PR 5: routing exposes the phase_context that was applied to this
# resolve call. Consumers can read it to know what trust level
# gated artifact loads, which upstreams were declared required vs
# optional, and which solution / diarization filters fired. The
# block is present for every phase: core phases get a "declared:
# false" placeholder so downstream code reads a uniform shape.
ROUTING_MAX_AGE_FOR_OUTPUT="null"
if [ -n "$ROUTING_MAX_AGE_DAYS" ] && [ "$ROUTING_MAX_AGE_DAYS" != "null" ]; then
  ROUTING_MAX_AGE_FOR_OUTPUT="$ROUTING_MAX_AGE_DAYS"
fi
ROUTING_LIMIT_FOR_OUTPUT="null"
if [ -n "$ROUTING_SOLUTION_LIMIT" ] && [ "$ROUTING_SOLUTION_LIMIT" != "null" ]; then
  ROUTING_LIMIT_FOR_OUTPUT="$ROUTING_SOLUTION_LIMIT"
fi
ROUTING_DECLARED_JSON=false
[ "$ROUTING_DECLARED" = true ] && ROUTING_DECLARED_JSON=true

jq -n \
  --arg phase "$PHASE" \
  --arg phase_kind "$PHASE_KIND" \
  --argjson artifacts "$ARTIFACTS_JSON" \
  --argjson upstream_status "$STATUS_JSON" \
  --argjson solutions "$SOLUTIONS_JSON" \
  --argjson precedents "$PRECEDENTS_JSON" \
  --argjson diarizations "$DIARIZATIONS_JSON" \
  --argjson config "$CONFIG_JSON" \
  --argjson goal "$GOAL" \
  --argjson metrics "$METRICS_JSON" \
  --argjson routing_declared "$ROUTING_DECLARED_JSON" \
  --arg     routing_trust "$ROUTING_TRUST" \
  --argjson routing_required "$ROUTING_REQUIRED_JSON" \
  --argjson routing_optional "$ROUTING_OPTIONAL_JSON" \
  --argjson routing_max_age "$ROUTING_MAX_AGE_FOR_OUTPUT" \
  --argjson routing_solution_tags "$ROUTING_SOLUTION_TAGS_JSON" \
  --argjson routing_solution_limit "$ROUTING_LIMIT_FOR_OUTPUT" \
  --argjson routing_diarization_paths "$ROUTING_DIARIZATION_PATHS_JSON" \
  --argjson routing_diarization_keywords "$ROUTING_DIARIZATION_KEYWORDS_JSON" \
  '{
    phase: $phase,
    phase_kind: $phase_kind,
    upstream_artifacts: $artifacts,
    upstream_status: $upstream_status,
    solutions: $solutions,
    conflict_precedents: $precedents,
    diarizations: $diarizations,
    config: $config,
    goal: $goal,
    sprint_metrics: $metrics,
    routing: {
      declared: $routing_declared,
      trust: $routing_trust,
      upstream_required: $routing_required,
      upstream_optional: $routing_optional,
      max_age_days: $routing_max_age,
      solutions: {
        tags: $routing_solution_tags,
        limit: $routing_solution_limit
      },
      diarizations: {
        paths: $routing_diarization_paths,
        keywords: $routing_diarization_keywords
      }
    }
  }'
