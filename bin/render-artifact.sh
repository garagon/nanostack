#!/usr/bin/env bash
# render-artifact.sh — Render a Nanostack JSON artifact as a static
# HTML view under $NANOSTACK_STORE/visual/. JSON remains canonical;
# this script is strictly downstream and writes only to the visual
# root. See reference/visual-artifact-contract.md for the full
# contract.
#
# Usage:
#   render-artifact.sh <phase> [artifact-path|--latest] [--strict]
#                              [--interactive] [--out <path>]
#                              [--manifest-only]
#
# PR 1 scope: /plan renderer + manifest + safety locks. Other phases
# exit 1 with a clear "phase not yet supported" message; PR 2 wires
# think/review/security/qa/ship. journal/stack are reserved for PR 3
# (exit 2). --interactive is reserved for PR 4 (exit 2).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
source "$SCRIPT_DIR/lib/html-escape.sh"
source "$SCRIPT_DIR/lib/visual-render.sh"
source "$SCRIPT_DIR/lib/artifact-trust.sh"
[ -f "$SCRIPT_DIR/lib/artifact-schemas.sh" ] && source "$SCRIPT_DIR/lib/artifact-schemas.sh"
# Sourced so render_journal_body / render_stack_body can ask the
# registry for custom phases and the project's phase_graph. Codex
# PR 3 pass 1 caught the missing source: nano_all_phases and
# nano_phase_graph_json were never defined, so journal silently
# skipped custom phases and stack fell back to "stack not found"
# instead of the project graph.
[ -f "$SCRIPT_DIR/lib/phases.sh" ] && source "$SCRIPT_DIR/lib/phases.sh"

usage() {
  cat <<USAGE
Usage: render-artifact.sh <phase> [artifact-path|--latest] [--strict]
                                  [--interactive] [--out <path>]
                                  [--manifest-only]

PR 1+2+3 scope:
  phase = plan|think|review|security|qa|ship
                             render the latest or explicit artifact
  phase = journal            render today's sprint journal view
                             (positional arg ignored; use --today or
                             --date YYYY-MM-DD)
  phase = stack [name]       render a custom stack DAG view; the
                             positional arg names the stack and is
                             looked up in .nanostack/config.json

Flags:
  --strict                   require nano_artifact_trust == verified
  --interactive              reserved for PR 4 (exit 2)
  --out <path>               write HTML to explicit path under \$NANOSTACK_STORE/visual
  --manifest-only            write manifest only, skip HTML
  --latest                   resolve via find-artifact.sh (default if no path)

Exit codes:
  0  success
  1  input error
  2  feature reserved for a later PR
  3  trust failure
  4  unsafe output path
USAGE
}

if [ $# -eq 0 ]; then
  usage >&2
  exit 1
fi

PHASE="$1"
shift

ART_PATH=""
USE_LATEST=false
STRICT=false
INTERACTIVE=false
MANIFEST_ONLY=false
OUT_PATH=""

# journal and stack are derived kinds (not phase artifacts). They
# follow different argument shapes from the per-phase renderers.
JOURNAL_DATE=""
STACK_NAME=""

# Argument parsing. The first non-flag argument after <phase> is the
# explicit artifact path. Flags can appear before or after.
while [ $# -gt 0 ]; do
  case "$1" in
    --latest)         USE_LATEST=true ;;
    --strict)         STRICT=true ;;
    --interactive)
      echo "render-artifact: --interactive is reserved for PR 4 (copy-only interactive mode)" >&2
      exit 2
      ;;
    --manifest-only)  MANIFEST_ONLY=true ;;
    --out)
      shift
      [ -z "${1:-}" ] && { echo "render-artifact: --out requires a path" >&2; exit 1; }
      OUT_PATH="$1"
      ;;
    --today)          JOURNAL_DATE="$(date -u +%Y-%m-%d)" ;;
    --date)
      shift
      [ -z "${1:-}" ] && { echo "render-artifact: --date requires YYYY-MM-DD" >&2; exit 1; }
      # Validate shape (codex pass 1 of PR 1 lesson: regex-validate
      # before passing to GNU date or storing in HTML).
      case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) JOURNAL_DATE="$1" ;;
        *) echo "render-artifact: --date must be YYYY-MM-DD" >&2; exit 1 ;;
      esac
      ;;
    --help|-h)        usage; exit 0 ;;
    -*)
      echo "render-artifact: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      # For journal/stack the positional is name/date, not artifact path.
      case "$PHASE" in
        journal)
          if [ -n "$JOURNAL_DATE" ]; then
            echo "render-artifact: extra positional for journal: $1" >&2
            exit 1
          fi
          case "$1" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) JOURNAL_DATE="$1" ;;
            *) echo "render-artifact: journal positional must be YYYY-MM-DD: $1" >&2; exit 1 ;;
          esac
          ;;
        stack)
          if [ -n "$STACK_NAME" ]; then
            echo "render-artifact: extra positional for stack: $1" >&2
            exit 1
          fi
          # Reject anything that is not alnum + dash.
          case "$1" in
            *[!a-zA-Z0-9_-]*)
              echo "render-artifact: stack name must be alnum/-/_ only: $1" >&2
              exit 1
              ;;
          esac
          STACK_NAME="$1"
          ;;
        *)
          if [ -n "$ART_PATH" ]; then
            echo "render-artifact: extra positional argument: $1" >&2
            exit 1
          fi
          ART_PATH="$1"
          ;;
      esac
      ;;
  esac
  shift
done

# Validate phase. Core phases: plan/think/review/security/qa/ship.
# Derived kinds: journal (PR 3), stack (PR 3).
case "$PHASE" in
  plan|think|review|security|qa|ship) ;;
  journal|stack) ;;
  *)
    echo "render-artifact: unsupported phase: $PHASE" >&2
    exit 1
    ;;
esac

# Default the journal date to today if neither --today nor --date
# was supplied (codex PR 3 pass 2: bare `journal` left this empty
# and the page banner read "journal · " with the filename containing
# a stray dash).
if [ "$PHASE" = "journal" ] && [ -z "$JOURNAL_DATE" ]; then
  JOURNAL_DATE="$(date -u +%Y-%m-%d)"
fi
# Stack name defaults to "default" so a bare `render-artifact.sh
# stack` exercises the project's phase_graph without forcing the
# caller to name a stack.
if [ "$PHASE" = "stack" ] && [ -z "$STACK_NAME" ]; then
  STACK_NAME="default"
fi

# Journal and stack do not source from a single phase artifact; they
# aggregate. Skip the per-phase trust/schema branch for them and use
# a sentinel ART_PHASE so the manifest writer below works uniformly.
if [ "$PHASE" = "journal" ] || [ "$PHASE" = "stack" ]; then
  ART_PATH=""
  ART_PHASE="$PHASE"
else
  # Resolve the source artifact. --no-session-sync keeps the renderer
  # strictly downstream: find-artifact.sh otherwise calls
  # `session.sh phase-start` as a convenience for skills, which would
  # mutate session.json just because a user viewed an artifact. Codex
  # PR 1 pass 7 caught the boundary violation.
  if [ -z "$ART_PATH" ] || [ "$USE_LATEST" = true ]; then
    ART_PATH=$("$SCRIPT_DIR/find-artifact.sh" "$PHASE" 30 --no-session-sync 2>/dev/null || true)
    if [ -z "$ART_PATH" ]; then
      echo "render-artifact: no $PHASE artifact found in the last 30 days" >&2
      exit 1
    fi
  fi

  if [ ! -f "$ART_PATH" ]; then
    echo "render-artifact: artifact not found: $ART_PATH" >&2
    exit 1
  fi

  # JSON must parse.
  if ! jq -e '.' "$ART_PATH" >/dev/null 2>&1; then
    echo "render-artifact: artifact is not valid JSON: $ART_PATH" >&2
    exit 1
  fi

  # .phase field must match the requested phase.
  ART_PHASE=$(jq -r '.phase? // ""' "$ART_PATH")
  if [ "$ART_PHASE" != "$PHASE" ]; then
    echo "render-artifact: artifact phase '$ART_PHASE' does not match requested phase '$PHASE': $ART_PATH" >&2
    exit 1
  fi
fi

# Trust check. integrity_mismatch always fails (exit 3). Under
# --strict, integrity_missing also fails. integrity_missing without
# strict renders with an "unverified" badge.
# Journal/stack aggregate many sources; per-source trust is rendered
# inline in the page, not on the page header badge.
if [ "$PHASE" = "journal" ] || [ "$PHASE" = "stack" ]; then
  TRUST="not_applicable"
else
  TRUST=$(nano_artifact_trust "$ART_PATH" 2>/dev/null || echo "not_found")
fi
case "$TRUST" in
  verified) ;;
  integrity_missing)
    if [ "$STRICT" = true ]; then
      echo "render-artifact: --strict requires verified trust; source is integrity_missing: $ART_PATH" >&2
      exit 3
    fi
    ;;
  integrity_mismatch)
    echo "render-artifact: source artifact integrity check failed: $ART_PATH" >&2
    exit 3
    ;;
  not_applicable)
    # Journal/stack: aggregated view. Trust shown inline per source.
    ;;
  *)
    echo "render-artifact: artifact unreadable: $ART_PATH" >&2
    exit 1
    ;;
esac

# Determine output paths.
TS=$(nano_visual_timestamp)
nano_visual_assert_safe_root

# Materialize the visual root before any path-safety check. Codex
# caught (PR 1 pass 1) that on a fresh store the visual root does not
# yet exist, so the canonical walk-up in nano_visual_assert_safe_output
# stops at $NANOSTACK_STORE, which is outside the canonical visual
# root path. Pre-creating visual/ keeps the realpath comparison stable.
mkdir -p "$(nano_visual_root)"

if [ -n "$OUT_PATH" ]; then
  nano_visual_assert_safe_output "$OUT_PATH"
  HTML_PATH="$OUT_PATH"
else
  case "$PHASE" in
    journal)
      mkdir -p "$(nano_visual_root)/journal"
      HTML_PATH="$(nano_visual_root)/journal/${TS}-journal-${JOURNAL_DATE}.html"
      ;;
    stack)
      mkdir -p "$(nano_visual_root)/stack/$STACK_NAME"
      HTML_PATH="$(nano_visual_root)/stack/$STACK_NAME/${TS}-stack-${STACK_NAME}.html"
      ;;
    *)
      HTML_PATH=$(nano_visual_html_path "$PHASE" "$TS")
      ;;
  esac
fi
case "$PHASE" in
  journal)
    MANIFEST_KIND="journal"
    MANIFEST_PATH="$(nano_visual_root)/manifests/${TS}-journal-${JOURNAL_DATE}.manifest.json"
    ;;
  stack)
    MANIFEST_KIND="stack"
    MANIFEST_PATH="$(nano_visual_root)/manifests/${TS}-stack-${STACK_NAME}.manifest.json"
    ;;
  *)
    MANIFEST_KIND="phase"
    MANIFEST_PATH=$(nano_visual_manifest_path "phase" "$PHASE" "$TS")
    ;;
esac

# Codex PR 1 pass 6 caught: even after lexical normalization passes
# the safety check, mkdir -p and mv use the ORIGINAL path, and the
# kernel resolves symlink components literally. A path like
# `visual/link/../evil.html` with `link` pointing outside collapses
# to `visual/evil.html` for the check but resolves to
# `outside/../evil.html` -> `outside/.../evil.html` at write time.
# Reassign HTML_PATH and MANIFEST_PATH to their normalized form so
# the kernel never traverses a `..` after a symlinked component.
HTML_PATH="$(nano_visual_normalize_path "$HTML_PATH")"
MANIFEST_PATH="$(nano_visual_normalize_path "$MANIFEST_PATH")"

# Refuse any symlink under visual/ on the path to HTML or manifest.
# Codex PR 1 pass 4 caught that mkdir -p / mv would happily write
# through a pre-existing visual/plan symlink to an outside target;
# nano_visual_assert_safe_root only guards the root itself.
nano_visual_assert_safe_descend "$HTML_PATH"
nano_visual_assert_safe_descend "$MANIFEST_PATH"

mkdir -p "$(dirname "$HTML_PATH")"
mkdir -p "$(dirname "$MANIFEST_PATH")"

# Manifest contract requires output_path to be absolute. If
# NANOSTACK_STORE was set to a relative path the derived HTML and
# manifest paths inherit the relativity, so canonicalize both before
# they reach the manifest body or the stdout that the caller sees.
# Codex PR 1 pass 3 caught the contract violation in the relative-
# store case.
nano_resolve_abs() {
  local p="$1"
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *)
      local dir base
      dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd)"
      base="$(basename "$p")"
      if [ -n "$dir" ]; then
        printf '%s/%s\n' "$dir" "$base"
      else
        printf '%s\n' "$p"
      fi
      ;;
  esac
}
HTML_PATH="$(nano_resolve_abs "$HTML_PATH")"
MANIFEST_PATH="$(nano_resolve_abs "$MANIFEST_PATH")"
if [ -n "$ART_PATH" ]; then
  ART_PATH="$(nano_resolve_abs "$ART_PATH")"
fi

# Pull the stored integrity hash. Journal/stack have no single source
# artifact (they aggregate), so SRC_INTEGRITY stays empty.
SRC_INTEGRITY=""
if [ -n "$ART_PATH" ]; then
  SRC_INTEGRITY=$(jq -r '.integrity // ""' "$ART_PATH" 2>/dev/null || echo "")
fi

# Optional schema validation. A failing schema does not block the
# render; it adds a visible warning to the HTML and is recorded in the
# manifest. This is intentional: a malformed artifact still benefits
# from being inspectable. Skipped for journal/stack.
SCHEMA_OK=true
SCHEMA_ERR=""
if [ -n "$ART_PATH" ] && declare -F nano_validate_artifact >/dev/null 2>&1; then
  if ! SCHEMA_ERR=$(nano_validate_artifact "$PHASE" "$(cat "$ART_PATH")" 2>&1); then
    SCHEMA_OK=false
  fi
fi

# ─── Phase renderers ────────────────────────────────────────
#
# Each function emits the body between page_start and page_end. They
# read named fields with jq, escape every scalar before printing, and
# render "Not recorded" / "None recorded" for absent values.

render_plan_body() {
  local artifact="$1"
  # Normalize: legacy --from-session plan artifacts store .summary as
  # a string and may omit .context_checkpoint entirely. Schema
  # validation already surfaces a warning above; here we coerce the
  # shape so the body still renders ("Not recorded" / "None recorded")
  # instead of jq crashing under set -e. Codex caught this on PR 1
  # pass 1: without the coercion, `render-artifact.sh plan --latest`
  # aborted on legacy artifacts the renderer was meant to inspect.
  local norm
  norm=$(jq -c '
    .summary           = (if (.summary | type)           == "object" then .summary           else {} end)
    | .context_checkpoint = (if (.context_checkpoint | type) == "object" then .context_checkpoint else {} end)
    | .summary.planned_files            = (if (.summary.planned_files            | type) == "array" then .summary.planned_files            else [] end)
    | .summary.risks                    = (if (.summary.risks                    | type) == "array" then .summary.risks                    else [] end)
    | .summary.out_of_scope             = (if (.summary.out_of_scope             | type) == "array" then .summary.out_of_scope             else [] end)
    | .context_checkpoint.key_files     = (if (.context_checkpoint.key_files     | type) == "array" then .context_checkpoint.key_files     else [] end)
    | .context_checkpoint.decisions_made= (if (.context_checkpoint.decisions_made| type) == "array" then .context_checkpoint.decisions_made else [] end)
    | .context_checkpoint.open_questions= (if (.context_checkpoint.open_questions| type) == "array" then .context_checkpoint.open_questions else [] end)
  ' "$artifact")

  local goal scope approval
  goal=$(printf '%s' "$norm" | jq -r '.summary.goal // "Not recorded"' | nano_html_escape)
  scope=$(printf '%s' "$norm" | jq -r '.summary.scope // "Not recorded"' | nano_html_escape)
  approval=$(printf '%s' "$norm" | jq -r '.summary.plan_approval // "Not recorded"' | nano_html_escape)

  cat <<HTML
    <section class="card">
      <h2>Summary</h2>
      <dl class="kvgrid">
        <dt>Goal</dt><dd>$goal</dd>
        <dt>Scope</dt><dd>$scope</dd>
        <dt>Approval</dt><dd>$approval</dd>
      </dl>
    </section>
HTML

  # Planned files. Reads from the normalized JSON so a legacy
  # artifact with .summary as a string still renders an empty list
  # instead of crashing.
  local files_count
  files_count=$(printf '%s' "$norm" | jq -r '.summary.planned_files | length')
  printf '    <section class="card">\n      <h2>Planned files (%s)</h2>\n' \
    "$(printf '%s' "$files_count" | nano_html_escape)"
  if [ "$files_count" = "0" ]; then
    printf '      <p class="muted">None recorded</p>\n'
  else
    printf '      <ul>\n'
    printf '%s' "$norm" | jq -r '.summary.planned_files | map(tostring) | sort | .[]' | while IFS= read -r f; do
      printf '        <li><code>%s</code></li>\n' "$(printf '%s' "$f" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  printf '    </section>\n'

  # Risks
  local risks_count
  risks_count=$(printf '%s' "$norm" | jq -r '.summary.risks | length')
  printf '    <section class="card">\n      <h2>Risks (%s)</h2>\n' \
    "$(printf '%s' "$risks_count" | nano_html_escape)"
  if [ "$risks_count" = "0" ]; then
    printf '      <p class="muted">None recorded</p>\n'
  else
    printf '      <ul>\n'
    printf '%s' "$norm" | jq -r '.summary.risks | .[] | tostring' | while IFS= read -r r; do
      printf '        <li>%s</li>\n' "$(printf '%s' "$r" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  printf '    </section>\n'

  # Out-of-scope
  local oos_count
  oos_count=$(printf '%s' "$norm" | jq -r '.summary.out_of_scope | length')
  printf '    <section class="card">\n      <h2>Out of scope (%s)</h2>\n' \
    "$(printf '%s' "$oos_count" | nano_html_escape)"
  if [ "$oos_count" = "0" ]; then
    printf '      <p class="muted">None recorded</p>\n'
  else
    printf '      <ul>\n'
    printf '%s' "$norm" | jq -r '.summary.out_of_scope | .[] | tostring' | while IFS= read -r item; do
      printf '        <li>%s</li>\n' "$(printf '%s' "$item" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  printf '    </section>\n'

  # Context checkpoint
  local ck_summary
  ck_summary=$(printf '%s' "$norm" | jq -r '.context_checkpoint.summary // "Not recorded"' | nano_html_escape)
  printf '    <section class="card">\n      <h2>Context checkpoint</h2>\n'
  printf '      <p>%s</p>\n' "$ck_summary"
  local kf_count
  kf_count=$(printf '%s' "$norm" | jq -r '.context_checkpoint.key_files | length')
  if [ "$kf_count" != "0" ]; then
    printf '      <h3>Key files</h3>\n      <ul>\n'
    printf '%s' "$norm" | jq -r '.context_checkpoint.key_files | .[] | tostring' | while IFS= read -r kf; do
      printf '        <li><code>%s</code></li>\n' "$(printf '%s' "$kf" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  local dec_count
  dec_count=$(printf '%s' "$norm" | jq -r '.context_checkpoint.decisions_made | length')
  if [ "$dec_count" != "0" ]; then
    printf '      <h3>Decisions made</h3>\n      <ul>\n'
    printf '%s' "$norm" | jq -r '.context_checkpoint.decisions_made | .[] | tostring' | while IFS= read -r d; do
      printf '        <li>%s</li>\n' "$(printf '%s' "$d" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  local oq_count
  oq_count=$(printf '%s' "$norm" | jq -r '.context_checkpoint.open_questions | length')
  if [ "$oq_count" != "0" ]; then
    printf '      <h3>Open questions</h3>\n      <ul>\n'
    printf '%s' "$norm" | jq -r '.context_checkpoint.open_questions | .[] | tostring' | while IFS= read -r q; do
      printf '        <li>%s</li>\n' "$(printf '%s' "$q" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  printf '    </section>\n'
}

render_think_body() {
  local artifact="$1"
  local norm
  norm=$(nano_visual_normalize_artifact "$artifact")

  local vp tu wedge risk scope_mode premise archetype arch_conf
  vp=$(printf '%s' "$norm" | jq -r '.summary.value_proposition // "Not recorded"' | nano_html_escape)
  tu=$(printf '%s' "$norm" | jq -r '.summary.target_user // "Not recorded"' | nano_html_escape)
  wedge=$(printf '%s' "$norm" | jq -r '.summary.narrowest_wedge // "Not recorded"' | nano_html_escape)
  risk=$(printf '%s' "$norm" | jq -r '.summary.key_risk // "Not recorded"' | nano_html_escape)
  scope_mode=$(printf '%s' "$norm" | jq -r '.summary.scope_mode // "Not recorded"' | nano_html_escape)
  premise=$(printf '%s' "$norm" | jq -r '.summary.premise_validated // false' | nano_html_escape)
  archetype=$(printf '%s' "$norm" | jq -r '.summary.archetype // "Not recorded"' | nano_html_escape)
  arch_conf=$(printf '%s' "$norm" | jq -r '.summary.archetype_confidence // "Not recorded"' | nano_html_escape)

  cat <<HTML
    <section class="card">
      <h2>Decision brief</h2>
      <dl class="kvgrid">
        <dt>Value proposition</dt><dd>$vp</dd>
        <dt>Target user</dt><dd>$tu</dd>
        <dt>Narrowest wedge</dt><dd>$wedge</dd>
        <dt>Key risk</dt><dd>$risk</dd>
        <dt>Scope mode</dt><dd><span class="chip">$scope_mode</span></dd>
        <dt>Premise validated</dt><dd>$premise</dd>
      </dl>
    </section>
    <section class="card">
      <h2>Archetype</h2>
      <dl class="kvgrid">
        <dt>Archetype</dt><dd><span class="chip">$archetype</span></dd>
        <dt>Confidence</dt><dd>$arch_conf</dd>
      </dl>
HTML
  # Example reference (only when present).
  local ex_name ex_path ex_why
  ex_name=$(printf '%s' "$norm" | jq -r '.summary.example_reference.name // ""' | nano_html_escape)
  if [ -n "$ex_name" ] && [ "$ex_name" != "null" ]; then
    ex_path=$(printf '%s' "$norm" | jq -r '.summary.example_reference.path // ""' | nano_html_escape)
    ex_why=$(printf '%s' "$norm" | jq -r '.summary.example_reference.why_relevant // ""' | nano_html_escape)
    cat <<HTML
      <h3>Example reference</h3>
      <p><code>$ex_name</code> — <code>$ex_path</code></p>
      <p class="muted">$ex_why</p>
HTML
  fi
  printf '    </section>\n'

  # Out of scope
  local oos_count
  oos_count=$(printf '%s' "$norm" | jq -r '.summary.out_of_scope | length')
  printf '    <section class="card">\n      <h2>Out of scope (%s)</h2>\n' \
    "$(printf '%s' "$oos_count" | nano_html_escape)"
  if [ "$oos_count" = "0" ]; then
    printf '      <p class="muted">None recorded</p>\n'
  else
    printf '      <ul>\n'
    printf '%s' "$norm" | jq -r '.summary.out_of_scope | .[] | tostring' | while IFS= read -r item; do
      printf '        <li>%s</li>\n' "$(printf '%s' "$item" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  printf '    </section>\n'

  render_context_checkpoint "$norm"
}

render_review_body() {
  local artifact="$1"
  local norm
  norm=$(nano_visual_normalize_artifact "$artifact")

  # Counts
  local blocking should_fix nitpicks positive
  blocking=$(printf '%s' "$norm" | jq -r '.summary.blocking // 0')
  should_fix=$(printf '%s' "$norm" | jq -r '.summary.should_fix // 0')
  nitpicks=$(printf '%s' "$norm" | jq -r '.summary.nitpicks // 0')
  positive=$(printf '%s' "$norm" | jq -r '.summary.positive // 0')

  cat <<HTML
    <section class="card">
      <h2>Review summary</h2>
      <div class="counters">
        <div class="counter" data-tone="bad"><span class="num">$(printf '%s' "$blocking" | nano_html_escape)</span><span class="label">Blocking</span></div>
        <div class="counter" data-tone="warn"><span class="num">$(printf '%s' "$should_fix" | nano_html_escape)</span><span class="label">Should fix</span></div>
        <div class="counter" data-tone="info"><span class="num">$(printf '%s' "$nitpicks" | nano_html_escape)</span><span class="label">Nitpicks</span></div>
        <div class="counter" data-tone="ok"><span class="num">$(printf '%s' "$positive" | nano_html_escape)</span><span class="label">Positive</span></div>
      </div>
    </section>
HTML

  # Scope drift
  local drift_status drift_count_oos drift_count_missing
  drift_status=$(printf '%s' "$norm" | jq -r '.scope_drift.status // "Not recorded"' | nano_html_escape)
  drift_count_oos=$(printf '%s' "$norm" | jq -r '.scope_drift.out_of_scope_files | length')
  drift_count_missing=$(printf '%s' "$norm" | jq -r '.scope_drift.missing_files | length')
  printf '    <section class="card">\n      <h2>Scope drift</h2>\n      <p>Status: <span class="chip">%s</span></p>\n' "$drift_status"
  if [ "$drift_count_oos" != "0" ]; then
    printf '      <h3>Out-of-scope files (%s)</h3>\n      <ul>\n' "$(printf '%s' "$drift_count_oos" | nano_html_escape)"
    printf '%s' "$norm" | jq -r '.scope_drift.out_of_scope_files | .[] | tostring' | while IFS= read -r f; do
      printf '        <li><code>%s</code></li>\n' "$(printf '%s' "$f" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  if [ "$drift_count_missing" != "0" ]; then
    printf '      <h3>Missing files (%s)</h3>\n      <ul>\n' "$(printf '%s' "$drift_count_missing" | nano_html_escape)"
    printf '%s' "$norm" | jq -r '.scope_drift.missing_files | .[] | tostring' | while IFS= read -r f; do
      printf '        <li><code>%s</code></li>\n' "$(printf '%s' "$f" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  printf '    </section>\n'

  # Findings
  render_findings_section "$norm" "Review findings"

  render_context_checkpoint "$norm"
}

render_security_body() {
  local artifact="$1"
  local norm
  norm=$(nano_visual_normalize_artifact "$artifact")

  local critical high medium low total
  critical=$(printf '%s' "$norm" | jq -r '.summary.critical // 0')
  high=$(printf '%s' "$norm" | jq -r '.summary.high // 0')
  medium=$(printf '%s' "$norm" | jq -r '.summary.medium // 0')
  low=$(printf '%s' "$norm" | jq -r '.summary.low // 0')
  total=$(printf '%s' "$norm" | jq -r '.summary.total_findings // 0')

  cat <<HTML
    <section class="card">
      <h2>Security summary</h2>
      <div class="counters">
        <div class="counter" data-tone="bad"><span class="num">$(printf '%s' "$critical" | nano_html_escape)</span><span class="label">Critical</span></div>
        <div class="counter" data-tone="warn"><span class="num">$(printf '%s' "$high" | nano_html_escape)</span><span class="label">High</span></div>
        <div class="counter" data-tone="info"><span class="num">$(printf '%s' "$medium" | nano_html_escape)</span><span class="label">Medium</span></div>
        <div class="counter" data-tone="ok"><span class="num">$(printf '%s' "$low" | nano_html_escape)</span><span class="label">Low</span></div>
        <div class="counter"><span class="num">$(printf '%s' "$total" | nano_html_escape)</span><span class="label">Total</span></div>
      </div>
    </section>
HTML

  render_findings_section "$norm" "Security findings"

  render_context_checkpoint "$norm"
}

render_qa_body() {
  local artifact="$1"
  local norm
  norm=$(nano_visual_normalize_artifact "$artifact")

  local mode status tests_run tests_passed tests_failed bugs_found bugs_fixed wtf
  mode=$(printf '%s' "$norm" | jq -r '.summary.mode // "Not recorded"' | nano_html_escape)
  status=$(printf '%s' "$norm" | jq -r '.summary.status // "Not recorded"' | nano_html_escape)
  tests_run=$(printf '%s' "$norm" | jq -r '.summary.tests_run // 0')
  tests_passed=$(printf '%s' "$norm" | jq -r '.summary.tests_passed // 0')
  tests_failed=$(printf '%s' "$norm" | jq -r '.summary.tests_failed // 0')
  bugs_found=$(printf '%s' "$norm" | jq -r '.summary.bugs_found // 0')
  bugs_fixed=$(printf '%s' "$norm" | jq -r '.summary.bugs_fixed // 0')
  wtf=$(printf '%s' "$norm" | jq -r '.summary.wtf_likelihood // "Not recorded"' | nano_html_escape)

  cat <<HTML
    <section class="card">
      <h2>QA summary</h2>
      <dl class="kvgrid">
        <dt>Mode</dt><dd><span class="chip">$mode</span></dd>
        <dt>Status</dt><dd><span class="chip">$status</span></dd>
        <dt>WTF likelihood</dt><dd>$wtf</dd>
      </dl>
      <div class="counters">
        <div class="counter"><span class="num">$(printf '%s' "$tests_run" | nano_html_escape)</span><span class="label">Tests run</span></div>
        <div class="counter" data-tone="ok"><span class="num">$(printf '%s' "$tests_passed" | nano_html_escape)</span><span class="label">Passed</span></div>
        <div class="counter" data-tone="bad"><span class="num">$(printf '%s' "$tests_failed" | nano_html_escape)</span><span class="label">Failed</span></div>
        <div class="counter" data-tone="warn"><span class="num">$(printf '%s' "$bugs_found" | nano_html_escape)</span><span class="label">Bugs found</span></div>
        <div class="counter" data-tone="ok"><span class="num">$(printf '%s' "$bugs_fixed" | nano_html_escape)</span><span class="label">Bugs fixed</span></div>
      </div>
    </section>
HTML

  render_findings_section "$norm" "QA findings"

  render_context_checkpoint "$norm"
}

render_ship_body() {
  local artifact="$1"

  # /ship has two modes: normal (object summary with pr_* fields) and
  # report_only (summary may be a string). Detect run_mode early.
  local run_mode
  run_mode=$(jq -r '.run_mode // (.summary.run_mode? // "normal")' "$artifact")

  if [ "$run_mode" = "report_only" ]; then
    # Report-only render: short, no release-packet styling.
    local rep
    rep=$(jq -r '
      if (.summary | type) == "string" then .summary
      else (.summary | tostring) end
    ' "$artifact" | nano_html_escape)
    cat <<HTML
    <section class="card">
      <h2>Ship report (run_mode = report_only)</h2>
      <p class="muted">This is a report of what would have shipped. No PR was created.</p>
      <pre>$rep</pre>
    </section>
HTML
    return 0
  fi

  # Normal ship artifact.
  local norm
  norm=$(nano_visual_normalize_artifact "$artifact")

  local pr_num pr_url title status ci_passed pr_url_raw url_safety
  pr_num=$(printf '%s' "$norm" | jq -r '.summary.pr_number // "Not recorded"' | nano_html_escape)
  pr_url_raw=$(printf '%s' "$norm" | jq -r '.summary.pr_url // ""')
  title=$(printf '%s' "$norm" | jq -r '.summary.title // "Not recorded"' | nano_html_escape)
  status=$(printf '%s' "$norm" | jq -r '.summary.status // "Not recorded"' | nano_html_escape)
  # Escape ci_passed even though the schema documents it as a
  # boolean. /ship's validator only requires summary to be an object,
  # so a malformed artifact with ci_passed as a string would inject
  # raw HTML otherwise. Codex PR 2 pass 1 caught the gap.
  ci_passed=$(printf '%s' "$norm" | jq -r '.summary.ci_passed // false' | nano_html_escape)

  url_safety=$(nano_visual_safe_pr_url "$pr_url_raw")

  cat <<HTML
    <section class="card">
      <h2>Release packet</h2>
      <dl class="kvgrid">
        <dt>Title</dt><dd>$title</dd>
        <dt>PR number</dt><dd>$pr_num</dd>
        <dt>PR URL</dt><dd>
HTML
  if [ "$url_safety" = "safe" ] && [ -n "$pr_url_raw" ]; then
    # Already validated as https://github.com/<owner>/<repo>... but
    # still escape both href and visible text. CSP allows form-action
    # 'none' and base-uri 'none', so the link cannot break out of the
    # local origin even if a parser quirk slipped through.
    local href_esc text_esc
    href_esc=$(printf '%s' "$pr_url_raw" | nano_attr_escape)
    text_esc=$(printf '%s' "$pr_url_raw" | nano_html_escape)
    printf '          <a class="pr-link" href="%s" rel="noopener noreferrer">%s</a>\n' "$href_esc" "$text_esc"
  elif [ -n "$pr_url_raw" ]; then
    # Unsafe URL: render as escaped text only, do NOT make it a link.
    printf '          <span class="unsafe-url" data-testid="unsafe-pr-url">%s</span>\n' \
      "$(printf '%s' "$pr_url_raw" | nano_html_escape)"
    printf '          <p class="muted">URL host not in the allowlist; rendered as text.</p>\n'
  else
    printf '          <span class="muted">Not recorded</span>\n'
  fi
  cat <<HTML
        </dd>
        <dt>Status</dt><dd><span class="chip">$status</span></dd>
        <dt>CI passed</dt><dd>$ci_passed</dd>
      </dl>
    </section>
HTML

  render_context_checkpoint "$norm"
}

# Shared helper for review/security/qa findings rendering. Reads
# .findings from the normalized JSON, escapes every scalar, groups by
# severity using nano_visual_severity_class. proof_of_concept (when
# present) renders inside <pre> so multi-line content stays readable
# without breaking the safety contract.
render_findings_section() {
  local norm="$1" title="$2"
  local count
  count=$(printf '%s' "$norm" | jq -r '.findings | length')
  printf '    <section class="card">\n      <h2>%s (%s)</h2>\n' \
    "$(printf '%s' "$title" | nano_html_escape)" \
    "$(printf '%s' "$count" | nano_html_escape)"
  if [ "$count" = "0" ]; then
    printf '      <p class="muted">None recorded</p>\n'
    printf '    </section>\n'
    return 0
  fi
  # Iterate findings with a single jq pass that emits NUL-delimited
  # records to keep multi-line description fields intact.
  printf '%s' "$norm" | jq -c '.findings[]' | while IFS= read -r f; do
    local fid sev cat desc file line poc fix conf reproduce root_cause fixed
    fid=$(printf '%s' "$f" | jq -r '.id // ""' | nano_html_escape)
    sev=$(printf '%s' "$f" | jq -r '.severity // "info"' | nano_html_escape)
    cat=$(printf '%s' "$f" | jq -r '.category // ""' | nano_html_escape)
    desc=$(printf '%s' "$f" | jq -r '.description // "(no description)"' | nano_html_escape)
    file=$(printf '%s' "$f" | jq -r '.file // ""' | nano_html_escape)
    line=$(printf '%s' "$f" | jq -r '.line // ""' | nano_html_escape)
    poc=$(printf '%s' "$f" | jq -r '.proof_of_concept // ""' | nano_html_escape)
    fix=$(printf '%s' "$f" | jq -r '.fix // ""' | nano_html_escape)
    conf=$(printf '%s' "$f" | jq -r '.confidence // ""' | nano_html_escape)
    reproduce=$(printf '%s' "$f" | jq -r '.reproduce // ""' | nano_html_escape)
    root_cause=$(printf '%s' "$f" | jq -r '.root_cause // ""' | nano_html_escape)
    fixed=$(printf '%s' "$f" | jq -r '.fixed // ""' | nano_html_escape)

    local sev_class
    sev_class=$(nano_visual_severity_class "$(printf '%s' "$f" | jq -r '.severity // "info"')")

    printf '      <div class="finding %s" data-severity="%s">\n' "$sev_class" "$sev"
    printf '        <div class="meta">'
    [ -n "$fid" ] && printf '<span class="id">%s</span> · ' "$fid"
    printf '<span class="chip %s">%s</span>' "$sev_class" "$sev"
    [ -n "$cat" ] && printf ' · <span class="chip">%s</span>' "$cat"
    if [ -n "$file" ]; then
      if [ -n "$line" ]; then
        printf ' · <code>%s:%s</code>' "$file" "$line"
      else
        printf ' · <code>%s</code>' "$file"
      fi
    fi
    [ -n "$conf" ] && printf ' · confidence %s' "$conf"
    printf '</div>\n'
    printf '        <p>%s</p>\n' "$desc"
    if [ -n "$poc" ]; then
      printf '        <details><summary>Proof of concept</summary><pre>%s</pre></details>\n' "$poc"
    fi
    if [ -n "$fix" ]; then
      printf '        <p><strong>Fix:</strong> %s</p>\n' "$fix"
    fi
    if [ -n "$reproduce" ]; then
      printf '        <details><summary>Reproduce</summary><pre>%s</pre></details>\n' "$reproduce"
    fi
    if [ -n "$root_cause" ]; then
      printf '        <p><strong>Root cause:</strong> %s</p>\n' "$root_cause"
    fi
    [ -n "$fixed" ] && [ "$fixed" != "false" ] && \
      printf '        <p class="muted">Fixed: %s</p>\n' "$fixed"
    printf '      </div>\n'
  done
  printf '    </section>\n'
}

# Shared helper for the context checkpoint card. Every core phase has
# the same checkpoint shape; centralizing keeps the visual identity
# consistent.
render_context_checkpoint() {
  local norm="$1"
  local ck_summary
  ck_summary=$(printf '%s' "$norm" | jq -r '.context_checkpoint.summary // "Not recorded"' | nano_html_escape)
  printf '    <section class="card">\n      <h2>Context checkpoint</h2>\n'
  printf '      <p>%s</p>\n' "$ck_summary"
  local kf_count
  kf_count=$(printf '%s' "$norm" | jq -r '.context_checkpoint.key_files | length')
  if [ "$kf_count" != "0" ]; then
    printf '      <h3>Key files</h3>\n      <ul>\n'
    printf '%s' "$norm" | jq -r '.context_checkpoint.key_files | .[] | tostring' | while IFS= read -r kf; do
      printf '        <li><code>%s</code></li>\n' "$(printf '%s' "$kf" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  local dec_count
  dec_count=$(printf '%s' "$norm" | jq -r '.context_checkpoint.decisions_made | length')
  if [ "$dec_count" != "0" ]; then
    printf '      <h3>Decisions made</h3>\n      <ul>\n'
    printf '%s' "$norm" | jq -r '.context_checkpoint.decisions_made | .[] | tostring' | while IFS= read -r d; do
      printf '        <li>%s</li>\n' "$(printf '%s' "$d" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  local oq_count
  oq_count=$(printf '%s' "$norm" | jq -r '.context_checkpoint.open_questions | length')
  if [ "$oq_count" != "0" ]; then
    printf '      <h3>Open questions</h3>\n      <ul>\n'
    printf '%s' "$norm" | jq -r '.context_checkpoint.open_questions | .[] | tostring' | while IFS= read -r q; do
      printf '        <li>%s</li>\n' "$(printf '%s' "$q" | nano_html_escape)"
    done
    printf '      </ul>\n'
  fi
  printf '    </section>\n'
}

# ─── Journal renderer ───────────────────────────────────────
#
# Aggregates every core + custom phase artifact for the current
# project on a given date and renders a phase timeline. The timeline
# shows: phase name, status (present / missing / tampered), summary,
# link to the per-phase render. SOURCE_ARTIFACTS_JSON is populated as
# the renderer walks phases so the manifest records every read source.

render_journal_body() {
  local date="$1"
  local project_path
  project_path="$(pwd)"
  # Codex PR 3 pass 1: --date <YYYY-MM-DD> previously called
  # find-artifact.sh which returns the LATEST in the last N days, not
  # the latest on the requested date. Compute the compact form
  # (YYYYMMDD) so we can filter artifact filenames by date prefix.
  local date_compact
  date_compact="${date//-/}"

  # find the latest artifact for <phase> on <date>. Uses filename
  # convention `YYYYMMDD-HHMMSS.json` under `.nanostack/<phase>/`.
  # Returns the path on stdout (empty if none).
  _journal_latest_on_date() {
    local ph="$1" dc="$2"
    local dir="$NANOSTACK_STORE/$ph"
    [ -d "$dir" ] || return 0
    local project_root="$project_path"
    # shellcheck disable=SC2012
    ls -1 "$dir"/"$dc"-*.json 2>/dev/null \
      | sort -r \
      | while IFS= read -r f; do
          # find-artifact.sh's project filter: .project must match.
          if jq -e --arg p "$project_root" '.project == $p' "$f" >/dev/null 2>&1; then
            printf '%s\n' "$f"
            return
          fi
        done | head -1
  }

  # Build the list of phases to enumerate. Use the phase registry
  # so custom phases declared in .nanostack/config.json appear too.
  local phases_list
  if declare -F nano_all_phases >/dev/null 2>&1; then
    phases_list=$(nano_all_phases 2>/dev/null || true)
  fi
  if [ -z "$phases_list" ]; then
    phases_list="think plan review qa security ship"
  fi

  printf '    <section class="card">\n      <h2>Sprint journal · %s</h2>\n' \
    "$(printf '%s' "$date" | nano_html_escape)"
  printf '      <p class="muted">Project: <code>%s</code></p>\n' \
    "$(printf '%s' "$project_path" | nano_html_escape)"
  printf '    </section>\n'

  # Phase timeline.
  printf '    <section class="card">\n      <h2>Phase timeline</h2>\n      <ol class="timeline">\n'
  local sources='[]'
  for ph in $phases_list; do
    [ -z "$ph" ] && continue
    case "$ph" in
      build) continue ;;  # Not a saved phase; build is editor work.
    esac
    # Find the latest artifact for this phase on the requested date.
    # _journal_latest_on_date filters by filename prefix YYYYMMDD,
    # which matches save-artifact.sh's naming convention. Falls back
    # to find-artifact.sh (last 30 days) when no date prefix matches,
    # because legacy artifacts may have different shapes. The first
    # match wins.
    local art_path trust status_label sev_class summary
    art_path=$(_journal_latest_on_date "$ph" "$date_compact")
    if [ -z "$art_path" ] && [ "$date" = "$(date -u +%Y-%m-%d)" ]; then
      # For today, fall back to find-artifact.sh to catch artifacts
      # not yet committed to disk under the convention.
      art_path=$("$SCRIPT_DIR/find-artifact.sh" "$ph" 30 --no-session-sync 2>/dev/null || true)
    fi
    if [ -z "$art_path" ] || [ ! -f "$art_path" ]; then
      status_label="missing"
      sev_class="sev-warn"
      trust="not_found"
      summary="No artifact found"
      printf '        <li class="timeline-item %s" data-phase="%s">' \
        "$sev_class" "$(printf '%s' "$ph" | nano_attr_escape)"
      printf '<span class="chip">%s</span> <span class="chip %s">%s</span> <span class="muted">%s</span>' \
        "$(printf '%s' "$ph" | nano_html_escape)" \
        "$sev_class" \
        "$(printf '%s' "$status_label" | nano_html_escape)" \
        "$(printf '%s' "$summary" | nano_html_escape)"
      printf '</li>\n'
      sources=$(printf '%s' "$sources" | jq -c \
        --arg phase "$ph" \
        --arg path "" \
        --arg integrity "" \
        --arg trust "$trust" \
        '. + [{phase: $phase, path: $path, integrity: $integrity, trust: $trust}]')
      continue
    fi
    art_path=$(nano_resolve_abs "$art_path")
    trust=$(nano_artifact_trust "$art_path" 2>/dev/null || echo "not_found")
    case "$trust" in
      verified)            status_label="verified"; sev_class="sev-ok" ;;
      integrity_missing)   status_label="unverified"; sev_class="sev-warn" ;;
      integrity_mismatch)  status_label="tampered"; sev_class="sev-bad" ;;
      *)                   status_label="unreadable"; sev_class="sev-warn" ;;
    esac
    # Phase-specific summary line.
    case "$ph" in
      think)   summary=$(jq -r '.summary.narrowest_wedge // .summary.value_proposition // "(no summary)"' "$art_path" 2>/dev/null) ;;
      plan)    summary=$(jq -r '.summary.goal // "(no summary)"' "$art_path" 2>/dev/null) ;;
      review)  summary=$(jq -r '"\(.summary.blocking // 0) blocking / \(.summary.should_fix // 0) should-fix / \(.summary.nitpicks // 0) nitpicks"' "$art_path" 2>/dev/null) ;;
      security) summary=$(jq -r '"\(.summary.critical // 0) critical / \(.summary.high // 0) high / \(.summary.total_findings // 0) total"' "$art_path" 2>/dev/null) ;;
      qa)      summary=$(jq -r '"\(.summary.tests_passed // 0)/\(.summary.tests_run // 0) tests / \(.summary.bugs_found // 0) bugs"' "$art_path" 2>/dev/null) ;;
      ship)
        if [ "$(jq -r '.run_mode // ""' "$art_path" 2>/dev/null)" = "report_only" ]; then
          summary="report_only"
        else
          summary=$(jq -r '"PR #\(.summary.pr_number // "?") · \(.summary.status // "unknown")"' "$art_path" 2>/dev/null)
        fi
        ;;
      *)       summary=$(jq -r '.summary | (if type == "object" then (.summary // (. | tostring)) else . end)' "$art_path" 2>/dev/null) ;;
    esac
    local integrity
    integrity=$(jq -r '.integrity // ""' "$art_path" 2>/dev/null)
    printf '        <li class="timeline-item %s" data-phase="%s" data-trust="%s">' \
      "$sev_class" \
      "$(printf '%s' "$ph" | nano_attr_escape)" \
      "$(printf '%s' "$trust" | nano_attr_escape)"
    printf '<span class="chip">%s</span> <span class="chip %s">%s</span> <span>%s</span>' \
      "$(printf '%s' "$ph" | nano_html_escape)" \
      "$sev_class" \
      "$(printf '%s' "$status_label" | nano_html_escape)" \
      "$(printf '%s' "$summary" | nano_html_escape)"
    printf '<div class="muted timeline-source">Source: <code>%s</code></div>' \
      "$(printf '%s' "$art_path" | nano_html_escape)"
    printf '</li>\n'
    sources=$(printf '%s' "$sources" | jq -c \
      --arg phase "$ph" \
      --arg path "$art_path" \
      --arg integrity "$integrity" \
      --arg trust "$trust" \
      '. + [{phase: $phase, path: $path, integrity: $integrity, trust: $trust}]')
  done
  printf '      </ol>\n    </section>\n'

  SOURCE_ARTIFACTS_JSON="$sources"
}

# ─── Stack renderer ─────────────────────────────────────────
#
# Renders a custom workflow stack as a DAG using SVG. Reads
# phase_graph either from a named stack file (examples/custom-stack-
# template/<name>/stack.json) or from .nanostack/config.json. For each
# node, looks up the latest artifact and shows trust status + last-
# render link if one exists under visual/.

render_stack_body() {
  local name="$1"

  # Locate the stack definition. Order:
  #   1. examples/custom-stack-template/<name>/stack.json (repo-bundled)
  #   2. $NANOSTACK_STORE/stacks/<name>/stack.json (user-installed)
  #   3. .nanostack/config.json (.phase_graph) for "default" / current project
  local stack_file=""
  local repo_root
  repo_root="$SCRIPT_DIR/.."
  if [ -f "$repo_root/examples/custom-stack-template/$name/stack.json" ]; then
    stack_file="$repo_root/examples/custom-stack-template/$name/stack.json"
  elif [ -f "$NANOSTACK_STORE/stacks/$name/stack.json" ]; then
    stack_file="$NANOSTACK_STORE/stacks/$name/stack.json"
  fi

  local graph_json=""
  local display_name="$name"
  local description=""

  if [ -n "$stack_file" ]; then
    graph_json=$(jq -c '.phase_graph' "$stack_file" 2>/dev/null || echo "")
    display_name=$(jq -r '.display_name // .name' "$stack_file" 2>/dev/null)
    description=$(jq -r '.description // ""' "$stack_file" 2>/dev/null)
  fi

  if [ -z "$graph_json" ] || [ "$graph_json" = "null" ]; then
    # Fall back to project's phase_graph via the registry.
    if declare -F nano_phase_graph_json >/dev/null 2>&1; then
      graph_json=$(nano_phase_graph_json 2>/dev/null || echo "")
    fi
  fi
  if [ -z "$graph_json" ] || [ "$graph_json" = "null" ]; then
    printf '    <section class="card">\n      <h2>Stack not found</h2>\n      <p>No stack definition found for <code>%s</code>.</p>\n    </section>\n' \
      "$(printf '%s' "$name" | nano_html_escape)"
    SOURCE_ARTIFACTS_JSON='[]'
    return 0
  fi

  printf '    <section class="card">\n      <h2>Custom stack · %s</h2>\n' \
    "$(printf '%s' "$display_name" | nano_html_escape)"
  if [ -n "$description" ]; then
    printf '      <p class="muted">%s</p>\n' "$(printf '%s' "$description" | nano_html_escape)"
  fi
  printf '    </section>\n'

  # Compute per-phase trust + last artifact path. Build the row list.
  local sources='[]'
  local node_count
  node_count=$(printf '%s' "$graph_json" | jq -r 'length')
  printf '    <section class="card">\n      <h2>Phase graph (%s phases)</h2>\n      <table>\n        <thead><tr><th>Phase</th><th>Depends on</th><th>Trust</th><th>Last artifact</th></tr></thead>\n        <tbody>\n' \
    "$(printf '%s' "$node_count" | nano_html_escape)"

  printf '%s' "$graph_json" | jq -c '.[]' | while IFS= read -r node; do
    local nname deps_csv art_path trust label
    nname=$(printf '%s' "$node" | jq -r '.name')
    deps_csv=$(printf '%s' "$node" | jq -r '.depends_on // [] | join(", ")')
    art_path=$("$SCRIPT_DIR/find-artifact.sh" "$nname" 30 --no-session-sync 2>/dev/null || true)
    if [ -n "$art_path" ] && [ -f "$art_path" ]; then
      art_path=$(nano_resolve_abs "$art_path")
      trust=$(nano_artifact_trust "$art_path" 2>/dev/null || echo "not_found")
      label="present"
    else
      art_path=""
      trust="missing"
      label="missing"
    fi
    local sev_class
    case "$trust" in
      verified)            sev_class="sev-ok"; label="verified" ;;
      integrity_missing)   sev_class="sev-warn"; label="unverified" ;;
      integrity_mismatch)  sev_class="sev-bad"; label="tampered" ;;
      missing)             sev_class="sev-warn" ;;
      *)                   sev_class="sev-warn"; label="unreadable" ;;
    esac
    printf '          <tr data-phase="%s" data-trust="%s">\n' \
      "$(printf '%s' "$nname" | nano_attr_escape)" \
      "$(printf '%s' "$trust" | nano_attr_escape)"
    printf '            <td><code>%s</code></td>\n' "$(printf '%s' "$nname" | nano_html_escape)"
    printf '            <td>%s</td>\n' \
      "$(if [ -n "$deps_csv" ]; then printf '<code>%s</code>' "$(printf '%s' "$deps_csv" | nano_html_escape)"; else printf '<span class="muted">none</span>'; fi)"
    printf '            <td><span class="chip %s">%s</span></td>\n' "$sev_class" \
      "$(printf '%s' "$label" | nano_html_escape)"
    if [ -n "$art_path" ]; then
      printf '            <td><code>%s</code></td>\n' "$(printf '%s' "$art_path" | nano_html_escape)"
    else
      printf '            <td><span class="muted">no artifact</span></td>\n'
    fi
    printf '          </tr>\n'
  done
  printf '        </tbody>\n      </table>\n    </section>\n'

  # SVG graph. Keep it simple: vertical chain with branch labels.
  # Layout: one column per "level" computed via depends_on depth.
  # We compute levels with jq + bash and lay out nodes on a grid.
  render_stack_svg "$graph_json"

  # Build sources array for the manifest using jq for correct JSON
  # escaping. Codex PR 3 pass 2: the previous awk builder only
  # escaped double quotes; a project path with a backslash or
  # control character produced invalid JSON.
  sources='[]'
  while IFS= read -r nm; do
    [ -z "$nm" ] && continue
    local ap tr ig
    ap=$("$SCRIPT_DIR/find-artifact.sh" "$nm" 30 --no-session-sync 2>/dev/null || true)
    if [ -n "$ap" ] && [ -f "$ap" ]; then
      ap=$(nano_resolve_abs "$ap")
      tr=$(nano_artifact_trust "$ap" 2>/dev/null || echo "not_found")
      ig=$(jq -r '.integrity // ""' "$ap" 2>/dev/null)
    else
      ap=""; tr="missing"; ig=""
    fi
    sources=$(printf '%s' "$sources" | jq -c \
      --arg phase "$nm" \
      --arg path "$ap" \
      --arg integrity "$ig" \
      --arg trust "$tr" \
      '. + [{phase: $phase, path: $path, integrity: $integrity, trust: $trust}]')
  done < <(printf '%s' "$graph_json" | jq -r '.[].name')

  SOURCE_ARTIFACTS_JSON="$sources"
}

# Emit a simple SVG DAG. Computes node levels by depends_on chain
# depth so the DAG flows left-to-right. Edges are drawn as straight
# lines between centers. No external assets; no JavaScript.
render_stack_svg() {
  local graph_json="$1"

  # Iterative depth resolution in bash. Root nodes (no depends_on) get
  # depth 0; children get 1 + max(parent depths). Cap rounds at the
  # node count + 1 so a valid topologically-unsorted graph is fully
  # resolved (worst case is a linear chain). Codex PR 3 pass 3 caught
  # the fixed cap of 10 truncating larger custom stacks.
  local names depths_tsv node_count round_cap
  names=$(printf '%s' "$graph_json" | jq -r '.[].name')
  node_count=$(printf '%s\n' "$names" | grep -c .)
  round_cap=$(( node_count + 1 ))
  : > "$TMP_ROOT_FALLBACK/depths.tsv"
  local round
  for round in $(seq 1 "$round_cap"); do
    local progressed=0
    for n in $names; do
      local already
      already=$(awk -F'\t' -v n="$n" '$1==n {print $2; exit}' "$TMP_ROOT_FALLBACK/depths.tsv")
      [ -n "$already" ] && continue
      local deps
      deps=$(printf '%s' "$graph_json" | jq -r --arg n "$n" '.[] | select(.name == $n) | .depends_on // [] | .[]')
      local max=-1 all_have=true
      for d in $deps; do
        local dd
        dd=$(awk -F'\t' -v n="$d" '$1==n {print $2; exit}' "$TMP_ROOT_FALLBACK/depths.tsv")
        if [ -z "$dd" ]; then all_have=false; break; fi
        [ "$dd" -gt "$max" ] && max="$dd"
      done
      if [ "$all_have" = true ]; then
        printf '%s\t%d\n' "$n" "$((max + 1))" >> "$TMP_ROOT_FALLBACK/depths.tsv"
        progressed=1
      fi
    done
    [ "$progressed" = 0 ] && break
  done

  # Build SVG: nodes positioned by depth column, with index-within-
  # column for y. Width 900, node 140x40, padding 20.
  local total_depth max_per_col
  total_depth=$(awk -F'\t' '{print $2}' "$TMP_ROOT_FALLBACK/depths.tsv" | sort -nu | tail -1)
  total_depth="${total_depth:-0}"
  max_per_col=$(awk -F'\t' '{print $2}' "$TMP_ROOT_FALLBACK/depths.tsv" | sort | uniq -c | awk '{print $1}' | sort -n | tail -1)
  max_per_col="${max_per_col:-1}"
  local svg_w=$(( (total_depth + 1) * 180 + 40 ))
  local svg_h=$(( max_per_col * 70 + 40 ))

  printf '    <section class="card">\n      <h2>DAG</h2>\n'
  # url-allowlist: the SVG xmlns is an XML namespace identifier; it
  # is not fetched and the browser ignores it as a URL. Required by
  # the SVG spec when SVG appears outside of an HTML5 parser.
  printf '      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="100%%" style="max-width:100%%;height:auto;background:var(--panel-2);border-radius:6px;">\n' \
    "$svg_w" "$svg_h"

  # Compute positions per node and persist.
  : > "$TMP_ROOT_FALLBACK/positions.tsv"
  local col col_index
  for col in $(seq 0 "$total_depth"); do
    col_index=0
    while IFS=$'\t' read -r nm d; do
      [ "$d" = "$col" ] || continue
      local x=$(( col * 180 + 20 ))
      local y=$(( col_index * 70 + 20 ))
      printf '%s\t%d\t%d\n' "$nm" "$x" "$y" >> "$TMP_ROOT_FALLBACK/positions.tsv"
      col_index=$((col_index + 1))
    done < "$TMP_ROOT_FALLBACK/depths.tsv"
  done

  # Draw edges first (under nodes).
  printf '%s' "$graph_json" | jq -r '.[] | .name as $n | .depends_on // [] | .[] | "\($n)\t\(.)"' \
    | while IFS=$'\t' read -r child parent; do
      local cx cy px py
      cx=$(awk -F'\t' -v n="$child" '$1==n {print $2+70}' "$TMP_ROOT_FALLBACK/positions.tsv")
      cy=$(awk -F'\t' -v n="$child" '$1==n {print $3+20}' "$TMP_ROOT_FALLBACK/positions.tsv")
      px=$(awk -F'\t' -v n="$parent" '$1==n {print $2+70}' "$TMP_ROOT_FALLBACK/positions.tsv")
      py=$(awk -F'\t' -v n="$parent" '$1==n {print $3+20}' "$TMP_ROOT_FALLBACK/positions.tsv")
      if [ -n "$cx" ] && [ -n "$px" ]; then
        printf '        <line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#666" stroke-width="1.5"/>\n' \
          "$px" "$py" "$cx" "$cy"
      fi
  done

  # Draw nodes with trust class.
  while IFS=$'\t' read -r nm x y; do
    local trust label fill stroke
    local ap
    ap=$("$SCRIPT_DIR/find-artifact.sh" "$nm" 30 --no-session-sync 2>/dev/null || true)
    if [ -n "$ap" ]; then
      trust=$(nano_artifact_trust "$ap" 2>/dev/null || echo "not_found")
    else
      trust="missing"
    fi
    case "$trust" in
      verified)            fill="#1f3a2a"; stroke="#4ade80"; label="ok" ;;
      integrity_missing)   fill="#3a321a"; stroke="#facc15"; label="?" ;;
      integrity_mismatch)  fill="#3a1f24"; stroke="#fb7185"; label="!" ;;
      *)                   fill="#2a2e38"; stroke="#666"; label="-" ;;
    esac
    local label_x label_y text_x text_y badge_x
    label_x=$(( x + 5 ))
    label_y=$(( y + 28 ))
    text_x=$(( x + 70 ))
    text_y=$(( y + 26 ))
    badge_x=$(( x + 135 - 14 ))
    local nm_esc
    nm_esc=$(printf '%s' "$nm" | nano_attr_escape)
    printf '        <g data-phase="%s" data-trust="%s">\n' "$nm_esc" "$(printf '%s' "$trust" | nano_attr_escape)"
    printf '          <rect x="%s" y="%s" width="140" height="40" rx="6" fill="%s" stroke="%s" stroke-width="2"/>\n' \
      "$x" "$y" "$fill" "$stroke"
    printf '          <text x="%s" y="%s" font-family="monospace" font-size="13" fill="#f4f4f5" text-anchor="middle">%s</text>\n' \
      "$text_x" "$text_y" "$(printf '%s' "$nm" | nano_html_escape)"
    printf '          <text x="%s" y="%s" font-size="11" fill="%s">%s</text>\n' \
      "$badge_x" "$label_y" "$stroke" "$(printf '%s' "$label" | nano_html_escape)"
    printf '        </g>\n'
  done < "$TMP_ROOT_FALLBACK/positions.tsv"

  printf '      </svg>\n    </section>\n'
}

# ─── Atomic write ───────────────────────────────────────────
# Codex PR 1 pass 8: a predictable temp name (HTML_PATH.tmp.$$) lets
# an attacker pre-create a symlink at that path; the redirect would
# follow it and write outside visual/. Use mktemp to create the
# files inside the already-validated parent directory; mktemp uses
# O_EXCL so a symlink-pre-creation race fails with a clear error
# instead of silently following the link.
TMP_HTML=$(mktemp "$HTML_PATH.tmp.XXXXXX" 2>/dev/null) || {
  echo "render-artifact: failed to create secure temp for HTML: $HTML_PATH" >&2
  exit 4
}
TMP_MFST=$(mktemp "$MANIFEST_PATH.tmp.XXXXXX" 2>/dev/null) || {
  rm -f "$TMP_HTML"
  echo "render-artifact: failed to create secure temp for manifest: $MANIFEST_PATH" >&2
  exit 4
}
# Scratch directory for renderer-internal state (stack layout, etc).
# mktemp on macOS does not accept --tmpdir without -t; use the
# portable directory form. Cleaned up via the EXIT trap below.
TMP_ROOT_FALLBACK=$(mktemp -d "${TMPDIR:-/tmp}/render-artifact.XXXXXX") || {
  echo "render-artifact: failed to create scratch dir" >&2
  rm -f "$TMP_HTML" "$TMP_MFST"
  exit 4
}

cleanup() {
  rm -f "$TMP_HTML" "$TMP_MFST" 2>/dev/null || true
  rm -rf "$TMP_ROOT_FALLBACK" 2>/dev/null || true
}
trap cleanup EXIT

CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ─── HTML ───────────────────────────────────────────────────
# Render the HTML first. The body renderers for journal/stack
# populate SOURCE_ARTIFACTS_JSON with the aggregated sources they
# read, so the manifest below describes what was actually rendered.
# A brace group is not a subshell in bash; SOURCE_ARTIFACTS_JSON
# survives outside.
if [ "$MANIFEST_ONLY" != true ]; then
  {
    nano_visual_page_start "$PHASE" "$TRUST" "static"

    if [ "$SCHEMA_OK" = false ]; then
      printf '    <div class="schema-warning" data-testid="schema-warning">%s</div>\n' \
        "$(printf 'Schema validation: %s' "$SCHEMA_ERR" | nano_html_escape)"
    fi

    case "$PHASE" in
      plan)     render_plan_body "$ART_PATH" ;;
      think)    render_think_body "$ART_PATH" ;;
      review)   render_review_body "$ART_PATH" ;;
      security) render_security_body "$ART_PATH" ;;
      qa)       render_qa_body "$ART_PATH" ;;
      ship)     render_ship_body "$ART_PATH" ;;
      journal)  render_journal_body "$JOURNAL_DATE" ;;
      stack)    render_stack_body "$STACK_NAME" ;;
    esac

    # Journal and stack do not have a single source artifact path or
    # integrity; the provenance footer points to the manifest only.
    if [ -n "$ART_PATH" ]; then
      nano_visual_page_end "$ART_PATH" "$MANIFEST_PATH" "$SRC_INTEGRITY"
    else
      nano_visual_page_end "(aggregated: ${PHASE})" "$MANIFEST_PATH" ""
    fi
  } > "$TMP_HTML"
else
  # In --manifest-only mode the body renderers still need to run so
  # the manifest can describe the aggregated sources. Render to the
  # bit bucket; the body still mutates SOURCE_ARTIFACTS_JSON.
  case "$PHASE" in
    journal) render_journal_body "$JOURNAL_DATE" >/dev/null ;;
    stack)   render_stack_body "$STACK_NAME"   >/dev/null ;;
  esac
fi

# ─── Manifest ───────────────────────────────────────────────
# Phase renders set SOURCE_ARTIFACTS_JSON to a single-element array
# from the source artifact; journal/stack body renderers set it to
# the aggregated source list.
if [ -z "${SOURCE_ARTIFACTS_JSON:-}" ]; then
  SOURCE_ARTIFACTS_JSON=$(jq -n \
    --arg src_phase "$ART_PHASE" \
    --arg src_path "${ART_PATH:-}" \
    --arg src_integrity "$SRC_INTEGRITY" \
    --arg src_trust "$TRUST" \
    '[{phase: $src_phase, path: $src_path, integrity: $src_integrity, trust: $src_trust}]')
fi

jq -n \
  --arg schema_version "1" \
  --arg kind "$MANIFEST_KIND" \
  --arg phase "$PHASE" \
  --argjson custom_phase false \
  --arg format "html" \
  --argjson interactive false \
  --argjson strict "$($STRICT && echo true || echo false)" \
  --argjson source_artifacts "$SOURCE_ARTIFACTS_JSON" \
  --arg output_path "$HTML_PATH" \
  --arg renderer_name "$NANO_VISUAL_RENDERER_NAME" \
  --arg renderer_version "$NANO_VISUAL_RENDERER_VERSION" \
  --arg created_at "$CREATED_AT" \
  --argjson schema_valid "$($SCHEMA_OK && echo true || echo false)" \
  --arg schema_error "$SCHEMA_ERR" \
  '{
    schema_version: $schema_version,
    kind: $kind,
    phase: $phase,
    custom_phase: $custom_phase,
    format: $format,
    interactive: $interactive,
    strict: $strict,
    source_artifacts: $source_artifacts,
    output_path: $output_path,
    renderer: { name: $renderer_name, version: $renderer_version },
    schema_valid: $schema_valid,
    schema_error: (if $schema_error == "" then null else $schema_error end),
    created_at: $created_at
  }' > "$TMP_MFST"

# Strict mode for aggregate renders: enforce after sources are
# collected, BEFORE the manifest-only branch returns. Codex PR 3
# pass 3 caught that running before the early exit was required so
# `journal --strict --manifest-only` cannot ship a "strict: true"
# manifest with tampered sources. "missing" sources stay acceptable
# because they are an expected aggregate state (the user has not
# run that phase yet). integrity_missing and integrity_mismatch are
# the actually-suspect cases.
if [ "$STRICT" = true ] && { [ "$PHASE" = "journal" ] || [ "$PHASE" = "stack" ]; }; then
  bad=$(printf '%s' "$SOURCE_ARTIFACTS_JSON" | jq -r \
    '.[] | select(.trust == "integrity_missing" or .trust == "integrity_mismatch") | "\(.phase): \(.trust)"' 2>/dev/null)
  if [ -n "$bad" ]; then
    echo "render-artifact: --strict requires every aggregated source to be verified; failing on:" >&2
    printf '  %s\n' $bad >&2
    exit 3
  fi
fi

if [ "$MANIFEST_ONLY" = true ]; then
  # Codex PR 1 pass 9: the manifest-only branch must not leave the
  # mktemp'd HTML temp file behind. Clean it before disabling the
  # cleanup trap. Same for the scratch dir (PR 3 pass 2).
  rm -f "$TMP_HTML"
  rm -rf "$TMP_ROOT_FALLBACK"
  mv "$TMP_MFST" "$MANIFEST_PATH"
  trap - EXIT
  echo "$MANIFEST_PATH"
  exit 0
fi

mv "$TMP_HTML" "$HTML_PATH"
mv "$TMP_MFST" "$MANIFEST_PATH"
# Codex PR 3 pass 2: the scratch dir was leaking on every successful
# render because the cleanup trap was unset before it was removed.
rm -rf "$TMP_ROOT_FALLBACK"
trap - EXIT

echo "$HTML_PATH"
