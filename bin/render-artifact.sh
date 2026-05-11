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

usage() {
  cat <<USAGE
Usage: render-artifact.sh <phase> [artifact-path|--latest] [--strict]
                                  [--interactive] [--out <path>]
                                  [--manifest-only]

PR 1+2 scope:
  phase = plan|think|review|security|qa|ship
                             render the latest or explicit artifact
  phase = journal            reserved for PR 3 (exit 2)
  phase = stack              reserved for PR 3 (exit 2)

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

# Reserved phase kinds. Surface a clear message and use the contract
# exit code so CI can categorize.
case "$PHASE" in
  journal)
    echo "render-artifact: 'journal' is reserved for PR 3 (sprint journal renderer)" >&2
    exit 2
    ;;
  stack)
    echo "render-artifact: 'stack' is reserved for PR 3 (custom stack graph renderer)" >&2
    exit 2
    ;;
esac

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
    --help|-h)        usage; exit 0 ;;
    -*)
      echo "render-artifact: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [ -n "$ART_PATH" ]; then
        echo "render-artifact: extra positional argument: $1" >&2
        exit 1
      fi
      ART_PATH="$1"
      ;;
  esac
  shift
done

# Validate phase. Core phases supported by PR 1+2: plan/think/review/
# security/qa/ship.
case "$PHASE" in
  plan|think|review|security|qa|ship) ;;
  *)
    echo "render-artifact: unsupported phase: $PHASE" >&2
    exit 1
    ;;
esac

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

# .phase field must match the requested phase. Codex PR 1 pass 6
# caught: a top-level JSON array or string crashes `jq -r '.phase //
# ""'` with exit 5 under set -e; the documented input-error exit is
# 1. The `?` operator suppresses the path error so non-object JSON
# falls through cleanly and the phase mismatch branch handles it.
ART_PHASE=$(jq -r '.phase? // ""' "$ART_PATH")
if [ "$ART_PHASE" != "$PHASE" ]; then
  echo "render-artifact: artifact phase '$ART_PHASE' does not match requested phase '$PHASE': $ART_PATH" >&2
  exit 1
fi

# Trust check. integrity_mismatch always fails (exit 3). Under
# --strict, integrity_missing also fails. integrity_missing without
# strict renders with an "unverified" badge.
TRUST=$(nano_artifact_trust "$ART_PATH" 2>/dev/null || echo "not_found")
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
  HTML_PATH=$(nano_visual_html_path "$PHASE" "$TS")
fi
MANIFEST_PATH=$(nano_visual_manifest_path "phase" "$PHASE" "$TS")

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
ART_PATH="$(nano_resolve_abs "$ART_PATH")"

# Pull the stored integrity hash. It is recorded in the manifest so a
# later check can decide whether the rendered view's source still
# matches what was on disk at render time.
SRC_INTEGRITY=$(jq -r '.integrity // ""' "$ART_PATH" 2>/dev/null || echo "")

# Optional schema validation. A failing schema does not block the
# render; it adds a visible warning to the HTML and is recorded in the
# manifest. This is intentional: a malformed artifact still benefits
# from being inspectable.
SCHEMA_OK=true
SCHEMA_ERR=""
if declare -F nano_validate_artifact >/dev/null 2>&1; then
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
  ci_passed=$(printf '%s' "$norm" | jq -r '.summary.ci_passed // false')

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
cleanup() {
  rm -f "$TMP_HTML" "$TMP_MFST" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Manifest ───────────────────────────────────────────────
# Build manifest first; if the HTML render fails we can still leave a
# clean state. We move both files into place at the very end.

CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Use jq to construct the manifest so all string escaping is correct.
jq -n \
  --arg schema_version "1" \
  --arg kind "phase" \
  --arg phase "$PHASE" \
  --argjson custom_phase false \
  --arg format "html" \
  --argjson interactive false \
  --argjson strict "$($STRICT && echo true || echo false)" \
  --arg src_phase "$ART_PHASE" \
  --arg src_path "$ART_PATH" \
  --arg src_integrity "$SRC_INTEGRITY" \
  --arg src_trust "$TRUST" \
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
    source_artifacts: [{
      phase: $src_phase,
      path: $src_path,
      integrity: $src_integrity,
      trust: $src_trust
    }],
    output_path: $output_path,
    renderer: { name: $renderer_name, version: $renderer_version },
    schema_valid: $schema_valid,
    schema_error: (if $schema_error == "" then null else $schema_error end),
    created_at: $created_at
  }' > "$TMP_MFST"

if [ "$MANIFEST_ONLY" = true ]; then
  # Codex PR 1 pass 9: the manifest-only branch must not leave the
  # mktemp'd HTML temp file behind. Clean it before disabling the
  # cleanup trap.
  rm -f "$TMP_HTML"
  mv "$TMP_MFST" "$MANIFEST_PATH"
  trap - EXIT
  echo "$MANIFEST_PATH"
  exit 0
fi

# ─── HTML ───────────────────────────────────────────────────
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
  esac

  nano_visual_page_end "$ART_PATH" "$MANIFEST_PATH" "$SRC_INTEGRITY"
} > "$TMP_HTML"

mv "$TMP_HTML" "$HTML_PATH"
mv "$TMP_MFST" "$MANIFEST_PATH"
trap - EXIT

echo "$HTML_PATH"
