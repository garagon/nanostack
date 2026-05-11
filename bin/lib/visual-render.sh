#!/usr/bin/env bash
# visual-render.sh — Shared page shell, CSP, trust badges, and output
# path safety for the visual artifact layer. Centralizing this here
# means every phase renderer in bin/render-artifact.sh gets the same
# CSS, the same security headers, and the same locked trust wording.
# Without a shared shell each phase would drift, and the
# ci/check-visual-artifact-templates.sh forbidden-pattern sweep would
# have to grep across many files.
#
# Public functions:
#   nano_visual_root                       echo $NANOSTACK_STORE/visual
#   nano_visual_output_dir <phase>         echo phase output directory
#   nano_visual_manifest_path <kind> <phase> <timestamp>
#                                          echo manifest path for a render
#   nano_visual_html_path <phase> <timestamp>
#                                          echo HTML path for a phase render
#   nano_visual_timestamp                  echo a deterministic YYYYMMDD-HHMMSS
#   nano_visual_assert_safe_output <path>  exit 4 if path escapes the visual root
#   nano_visual_assert_safe_root           exit 4 if visual/ is a symlink
#   nano_visual_csp <static|interactive>   echo the CSP value
#   nano_visual_trust_badge_text <status>  echo the locked badge wording
#   nano_visual_page_start <phase> <trust> emit the page shell start
#   nano_visual_page_end <source_path> <manifest_path> <integrity>
#                                          emit the provenance footer + close
#
# Every renderer writes through these helpers; phase-specific bodies
# render between page_start and page_end.

if [ "${_NANO_VISUAL_RENDER_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_NANO_VISUAL_RENDER_LOADED=1

if [ -z "${NANOSTACK_STORE:-}" ]; then
  echo "visual-render.sh: NANOSTACK_STORE not set; source bin/lib/store-path.sh first" >&2
  return 1 2>/dev/null || exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/html-escape.sh"

NANO_VISUAL_RENDERER_NAME="nanostack-html-renderer"
NANO_VISUAL_RENDERER_VERSION="1"

nano_visual_root() {
  printf '%s\n' "$NANOSTACK_STORE/visual"
}

nano_visual_output_dir() {
  local phase="$1"
  local custom="${2:-false}"
  if [ "$custom" = "true" ]; then
    printf '%s\n' "$NANOSTACK_STORE/visual/custom/$phase"
  else
    printf '%s\n' "$NANOSTACK_STORE/visual/$phase"
  fi
}

nano_visual_timestamp() {
  date -u +%Y%m%d-%H%M%S
}

nano_visual_html_path() {
  local phase="$1"
  local timestamp="$2"
  local custom="${3:-false}"
  printf '%s/%s-%s.html\n' \
    "$(nano_visual_output_dir "$phase" "$custom")" \
    "$timestamp" \
    "$phase"
}

nano_visual_manifest_path() {
  local kind="$1"   # phase | journal | stack
  local phase="$2"
  local timestamp="$3"
  local custom="${4:-false}"
  local stem
  if [ "$custom" = "true" ]; then
    stem="$timestamp-custom-$phase"
  else
    stem="$timestamp-$phase"
  fi
  printf '%s/manifests/%s.manifest.json\n' \
    "$NANOSTACK_STORE/visual" \
    "$stem"
}

# Refuse to follow a symlinked visual root. The renderer otherwise
# would write to whatever the symlink resolves to, which can escape
# the store. The contract requires the visual root be a plain
# directory (or absent, in which case we mkdir it ourselves).
nano_visual_assert_safe_root() {
  local root
  root="$(nano_visual_root)"
  if [ -L "$root" ]; then
    echo "render-artifact: refusing to write under symlinked visual root: $root" >&2
    return 4
  fi
  return 0
}

# Refuse to write into any subdirectory under visual/ that is a
# symlink. Codex PR 1 pass 4 caught this: if visual/plan was already
# a symlink to /tmp/outside, mkdir -p accepted it and the later
# atomic mv wrote into the target, escaping the visual root despite
# the lexical path-safety check on --out. Walk from the visual root
# down to (but not including) the leaf file, asserting -L is false at
# every existing intermediate.
#
# Called after nano_visual_normalize_path has rewritten the candidate
# path, so the input is already absolute and ".." is resolved.
nano_visual_assert_safe_descend() {
  local path="$1"  # absolute, normalized
  local root
  root="$(nano_visual_normalize_path "$(nano_visual_root)")"
  # Require the path to live under the canonical root. The caller
  # already verified this via nano_visual_assert_safe_output for --out;
  # we re-check for safety in case this helper is reused later.
  case "$path" in
    "$root"|"$root"/*) ;;
    *)
      echo "render-artifact: refusing to write outside $root: $path" >&2
      return 4
      ;;
  esac
  local rel="${path#"$root"}"
  rel="${rel#/}"
  local current="$root"
  if [ -L "$current" ]; then
    echo "render-artifact: visual root is a symlink: $current" >&2
    return 4
  fi
  local IFS=/
  # shellcheck disable=SC2086
  set -- $rel
  local part
  # The last component is the leaf file. Drop it so we only check
  # directory components (intermediate dirs can be symlinks; the
  # file itself is created by the renderer's atomic move).
  local count=$#
  local i=0
  for part in "$@"; do
    i=$((i+1))
    [ "$i" = "$count" ] && break
    current="$current/$part"
    if [ -L "$current" ]; then
      echo "render-artifact: refusing to descend into symlinked subdirectory: $current" >&2
      return 4
    fi
  done
  return 0
}

# Lexically normalize an absolute path: resolve "." and ".." components
# without touching the filesystem. This defeats --out escapes through
# missing directory segments followed by ".." (codex caught the gap
# on PR 1 pass 2: a path like .../visual/new/../../outside.html passed
# the previous "walk up to nearest existing ancestor" check because
# the missing 'new' segment never appeared on disk for realpath to
# resolve, leaving the comparison anchored at visual/).
#
# This implementation is pure shell so it runs on the same Bash 3.2
# that ships with macOS without depending on `realpath -m`.
nano_visual_normalize_path() {
  local raw="$1"
  case "$raw" in
    /*) ;;
    *) raw="$PWD/$raw" ;;
  esac
  local out=""
  local IFS=/
  # shellcheck disable=SC2086
  set -- $raw
  local part
  for part in "$@"; do
    case "$part" in
      ""|.) ;;
      ..)
        # Pop the last segment from $out if any.
        if [ -n "$out" ]; then
          out="${out%/*}"
        fi
        ;;
      *)
        out="$out/$part"
        ;;
    esac
  done
  [ -z "$out" ] && out="/"
  printf '%s\n' "$out"
}

# Refuse output paths that escape the visual root after lexical
# normalization. The visual root is canonicalized through realpath
# when present (so a real-but-non-symlinked root resolves cleanly);
# the caller path is normalized lexically because it may include
# directories that do not exist yet.
nano_visual_assert_safe_output() {
  local path="$1"
  local root
  root="$(nano_visual_root)"
  case "$path" in
    /*) ;;
    *)
      echo "render-artifact: --out must be an absolute path: $path" >&2
      return 4
      ;;
  esac

  # Both root and path are normalized lexically so a symlinked
  # filesystem path (for example /tmp -> /private/tmp on macOS) does
  # not produce a false mismatch: realpath would expand the root and
  # not the not-yet-existing path, and the prefix check would fail.
  # The renderer's threat model treats the visual root's symlink
  # status as the one filesystem property worth checking
  # (nano_visual_assert_safe_root); deeper symlink chains are out of
  # scope for the path-safety check, which is purely about defeating
  # ".." escape and absolute-path misrouting in --out.
  local path_canon root_canon
  path_canon="$(nano_visual_normalize_path "$path")"
  root_canon="$(nano_visual_normalize_path "$root")"

  case "$path_canon" in
    "$root_canon"/*) return 0 ;;
    *)
      echo "render-artifact: refusing to write outside $root_canon: $path (normalized: $path_canon)" >&2
      return 4
      ;;
  esac
}

nano_visual_csp() {
  local mode="${1:-static}"
  case "$mode" in
    interactive)
      # Reserved for PR 4. Inline script will be enabled here only when
      # the copy-only contract is verified. Until then, callers in
      # PR 1 must request "static".
      printf "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\n"
      ;;
    *)
      printf "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\n"
      ;;
  esac
}

# Locked trust badge wording. CI greps for these exact strings.
nano_visual_trust_badge_text() {
  local status="${1:-not_found}"
  case "$status" in
    verified)            printf 'verified\n' ;;
    integrity_missing)   printf 'unverified\n' ;;
    integrity_mismatch)  printf 'tampered\n' ;;
    *)                   printf 'unknown\n' ;;
  esac
}

# Page shell: doctype, head with CSP and CSS, hero header with trust
# badge. The phase body follows this and nano_visual_page_end closes.
nano_visual_page_start() {
  local phase="$1"
  local trust="$2"
  local csp_mode="${3:-static}"
  local custom="${4:-false}"

  local phase_esc trust_esc badge_text title_phase
  phase_esc="$(printf '%s' "$phase" | nano_attr_escape)"
  trust_esc="$(printf '%s' "$trust" | nano_attr_escape)"
  badge_text="$(nano_visual_trust_badge_text "$trust")"
  if [ "$custom" = "true" ]; then
    title_phase="$phase (custom)"
  else
    title_phase="/$phase"
  fi
  local title_esc
  title_esc="$(printf '%s' "$title_phase" | nano_html_escape)"

  cat <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="$(nano_visual_csp "$csp_mode")">
  <title>Nanostack $title_esc visual artifact</title>
  <style>
    :root {
      --bg: #0f1115;
      --panel: #171a21;
      --panel-2: #20242d;
      --fg: #f4f4f5;
      --muted: #b7bbc5;
      --line: #343946;
      --ok: #4ade80;
      --warn: #facc15;
      --bad: #fb7185;
      --info: #60a5fa;
    }
    * { box-sizing: border-box; }
    html, body { background: var(--bg); color: var(--fg); margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; line-height: 1.5; }
    .page { max-width: 1120px; margin: 0 auto; padding: 24px; }
    @media (max-width: 720px) { .page { padding: 16px; } }
    .hero { border-bottom: 1px solid var(--line); padding-bottom: 16px; margin-bottom: 24px; }
    .eyebrow { color: var(--muted); font-size: 0.85rem; margin: 0 0 6px 0; text-transform: uppercase; letter-spacing: 0.05em; }
    h1 { margin: 0 0 8px 0; font-size: 1.8rem; }
    .trust-badge { display: inline-block; padding: 4px 10px; border-radius: 4px; font-size: 0.85rem; font-weight: 600; }
    .trust-badge[data-trust="verified"] { background: rgba(74,222,128,0.15); color: var(--ok); border: 1px solid var(--ok); }
    .trust-badge[data-trust="integrity_missing"] { background: rgba(250,204,21,0.15); color: var(--warn); border: 1px solid var(--warn); }
    .trust-badge[data-trust="integrity_mismatch"] { background: rgba(251,113,133,0.15); color: var(--bad); border: 1px solid var(--bad); }
    section.card { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 16px; margin-bottom: 16px; }
    section.card h2 { margin: 0 0 12px 0; font-size: 1.15rem; }
    .muted { color: var(--muted); }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { color: var(--muted); font-weight: 600; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.03em; }
    code, pre { background: var(--panel-2); border: 1px solid var(--line); border-radius: 4px; padding: 2px 6px; font-family: "SFMono-Regular", Consolas, monospace; font-size: 0.85rem; }
    pre { padding: 12px; overflow-x: auto; }
    ul { padding-left: 20px; margin: 0; }
    li { margin-bottom: 4px; }
    .provenance { color: var(--muted); font-size: 0.85rem; border-top: 1px solid var(--line); padding-top: 16px; margin-top: 32px; }
    .provenance p { margin: 4px 0; word-break: break-all; }
    .kvgrid { display: grid; grid-template-columns: max-content 1fr; gap: 6px 16px; }
    .kvgrid dt { color: var(--muted); }
    .kvgrid dd { margin: 0; }
    .schema-warning { background: rgba(250,204,21,0.1); border: 1px solid var(--warn); color: var(--warn); padding: 12px; border-radius: 6px; margin-bottom: 16px; }
  </style>
</head>
<body>
  <main class="page" data-nanostack-visual="1" data-phase="$phase_esc">
    <header class="hero">
      <p class="eyebrow">Nanostack visual artifact</p>
      <h1>$title_esc</h1>
      <p class="trust-badge" data-trust="$trust_esc">$(printf '%s' "$badge_text" | nano_html_escape)</p>
    </header>
HTML
}

# Closes the page with provenance pointing back to the source artifact
# and the companion manifest. Every render must call this so the
# audit trail is locked in HTML.
nano_visual_page_end() {
  local source_path="$1"
  local manifest_path="$2"
  local integrity="${3:-}"

  local src_esc mfst_esc integ_esc
  src_esc="$(printf '%s' "$source_path" | nano_html_escape)"
  mfst_esc="$(printf '%s' "$manifest_path" | nano_html_escape)"
  if [ -n "$integrity" ]; then
    integ_esc="$(printf '%s' "$integrity" | nano_html_escape)"
  else
    integ_esc="not recorded"
  fi

  cat <<HTML
    <footer class="provenance" data-testid="visual-provenance">
      <p>Source artifact: <code data-testid="source-artifact-path">$src_esc</code></p>
      <p>Manifest: <code data-testid="visual-manifest-path">$mfst_esc</code></p>
      <p>Source integrity (SHA-256): <code>$integ_esc</code></p>
      <p>Renderer: $NANO_VISUAL_RENDERER_NAME v$NANO_VISUAL_RENDERER_VERSION</p>
    </footer>
  </main>
</body>
</html>
HTML
}
