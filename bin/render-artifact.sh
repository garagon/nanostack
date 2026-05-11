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

PR 1 scope:
  phase = plan               render the latest or explicit /plan artifact
  phase = think|review|security|qa|ship
                             reserved for PR 2 (exit 1)
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

# Validate phase. Core phases supported by PR 1: plan. The rest of the
# core phases will be wired in PR 2; report a clear message.
case "$PHASE" in
  plan) ;;
  think|review|security|qa|ship)
    echo "render-artifact: phase '$PHASE' is reserved for PR 2 (core phase renderers)" >&2
    exit 1
    ;;
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

# ─── Atomic write ───────────────────────────────────────────
TMP_HTML="$HTML_PATH.tmp.$$"
TMP_MFST="$MANIFEST_PATH.tmp.$$"
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
    plan)   render_plan_body "$ART_PATH" ;;
  esac

  nano_visual_page_end "$ART_PATH" "$MANIFEST_PATH" "$SRC_INTEGRITY"
} > "$TMP_HTML"

mv "$TMP_HTML" "$HTML_PATH"
mv "$TMP_MFST" "$MANIFEST_PATH"
trap - EXIT

echo "$HTML_PATH"
