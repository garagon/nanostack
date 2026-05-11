#!/usr/bin/env bash
# check-visual-artifact-templates.sh — Static safety lint for the
# visual artifact layer.
#
# Greps the renderer and shared shell for patterns that would break
# the Visual Artifact Contract:
#
#   - external network references (http://, https://) in templates
#   - script-loading or XHR-style APIs
#   - browser-side storage / cookie access
#   - eval / new Function
#   - missing CSP / data-nanostack-visual markers in the shared shell
#   - trust badge wording must use the locked strings
#
# Scope is intentionally narrow: only files that emit HTML for the
# visual layer. The list is hardcoded so adding a new renderer file
# requires touching this script (auditable diff).

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

FILES=(
  "bin/render-artifact.sh"
  "bin/lib/visual-render.sh"
  "bin/lib/html-escape.sh"
)

PASS=0
FAIL=0
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

check_absent() {
  local name="$1"; local pattern="$2"; shift 2
  local files=("$@")
  # `-e -- ` so a pattern starting with `-` (e.g. `--no-session-sync`)
  # is not interpreted as a grep flag.
  if grep -nE -e "$pattern" -- "${files[@]}" >/dev/null 2>&1; then
    FAIL=$((FAIL+1))
    printf "  ${RED}FAIL${NC}  %s\n" "$name"
    printf "         ${DIM}pattern: %s${NC}\n" "$pattern"
    grep -nE -e "$pattern" -- "${files[@]}" | sed 's/^/         /' || true
  else
    PASS=$((PASS+1))
    printf "  ${GREEN}OK${NC}    %s\n" "$name"
  fi
}

check_present() {
  local name="$1"; local pattern="$2"; shift 2
  local files=("$@")
  if grep -nE -e "$pattern" -- "${files[@]}" >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf "  ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "  ${RED}FAIL${NC}  %s (pattern missing)\n" "$name"
    printf "         ${DIM}pattern: %s${NC}\n" "$pattern"
  fi
}

printf "\n${GREEN}=== Visual artifact template safety ===${NC}\n\n"

# 1. No external URLs in template emission lines. We allow URLs to
# appear inside the source as case-pattern allowlists (PR 2 added
# nano_visual_safe_pr_url to validate ship pr_url strings), but they
# must never appear as literal HTML emitted by the renderer. The
# grep filter excludes lines that are case patterns, comments, or
# expansion sentinels for the URL allowlist itself.
check_absent_no_allowlist() {
  local name="$1"
  local pattern="$2"
  shift 2
  local files=("$@")
  local hits
  hits=$(grep -nE "$pattern" "${files[@]}" 2>/dev/null \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
    | grep -vE '# url-allowlist' \
    | grep -vE 'xmlns="http://www\.w3\.org/' \
    | grep -vE 'http://\*\|https://\*' \
    || true)
  if [ -n "$hits" ]; then
    FAIL=$((FAIL+1))
    printf "  ${RED}FAIL${NC}  %s\n" "$name"
    printf "         ${DIM}pattern: %s${NC}\n" "$pattern"
    printf '%s\n' "$hits" | sed 's/^/         /'
  else
    PASS=$((PASS+1))
    printf "  ${GREEN}OK${NC}    %s\n" "$name"
  fi
}
check_absent_no_allowlist "no http(s) URLs in renderer/templates (allowlist excepted)" \
  'https?://' "${FILES[@]}"

# 2. No script-loading or XHR-style APIs.
check_absent "no <script src=" \
  '<script[[:space:]]+src=' "${FILES[@]}"
check_absent "no fetch(" \
  'fetch[[:space:]]*\(' "${FILES[@]}"
check_absent "no XMLHttpRequest" \
  'XMLHttpRequest' "${FILES[@]}"
check_absent "no navigator.sendBeacon" \
  'navigator\.sendBeacon' "${FILES[@]}"

# 3. No browser-side storage or cookie access.
check_absent "no localStorage" \
  'localStorage' "${FILES[@]}"
check_absent "no sessionStorage" \
  'sessionStorage' "${FILES[@]}"
check_absent "no document.cookie" \
  'document\.cookie' "${FILES[@]}"

# 4. No eval / Function constructor.
check_absent "no eval(" \
  'eval[[:space:]]*\(' "${FILES[@]}"
check_absent "no new Function(" \
  'new[[:space:]]+Function[[:space:]]*\(' "${FILES[@]}"

# 5. Shared shell must include CSP and the visual marker.
check_present "shared shell emits CSP" \
  "Content-Security-Policy" "bin/lib/visual-render.sh"
check_present "shared shell emits data-nanostack-visual" \
  'data-nanostack-visual' "bin/lib/visual-render.sh"
check_present "shared shell emits provenance testid" \
  'data-testid="visual-provenance"' "bin/lib/visual-render.sh"

# 6. Trust badge wording is locked: 'verified', 'unverified',
# 'tampered'. Anything else for these statuses fails. We check the
# shared function uses these exact words.
check_present "trust badge: verified" \
  "printf 'verified" "bin/lib/visual-render.sh"
check_present "trust badge: unverified (integrity_missing)" \
  "printf 'unverified" "bin/lib/visual-render.sh"
check_present "trust badge: tampered (integrity_mismatch)" \
  "printf 'tampered" "bin/lib/visual-render.sh"

# 7. Static-mode CSP must include default-src 'none' so the static
# renderer in PR 1 cannot accidentally widen the policy. Interactive
# mode (PR 4) gets its own check when wired.
check_present "static CSP default-src 'none'" \
  "default-src 'none'" "bin/lib/visual-render.sh"

# 8. Renderer must source the escape helpers, not inline its own.
check_present "renderer sources html-escape" \
  'source.*lib/html-escape.sh' "bin/render-artifact.sh"
check_present "renderer sources visual-render" \
  'source.*lib/visual-render.sh' "bin/render-artifact.sh"
check_present "renderer sources artifact-trust" \
  'source.*lib/artifact-trust.sh' "bin/render-artifact.sh"

# 9. PR 2: ship renderer must escape PR URLs and use the allowlist.
check_present "ship renderer calls nano_visual_safe_pr_url" \
  'nano_visual_safe_pr_url' "bin/render-artifact.sh"
check_present "ship renderer wraps URL with rel='noopener noreferrer'" \
  'noopener noreferrer' "bin/render-artifact.sh"

# 10. PR 2: severity classes must come from the shared helper, not be
# inlined. Lets PR 3 / 4 keep them consistent.
check_present "renderer uses nano_visual_severity_class" \
  'nano_visual_severity_class' "bin/render-artifact.sh"

# 11. PR 2: shared CSS must include severity finding styles so every
# core phase shares the visual identity.
check_present "shared CSS defines .finding.sev-bad" \
  '\.finding\.sev-bad' "bin/lib/visual-render.sh"
check_present "shared CSS defines .counter" \
  '\.counter' "bin/lib/visual-render.sh"

# 12. PR 3: journal renderer reads through _journal_latest_on_date
# (a direct filesystem helper) and never calls session.sh
# phase-start or other mutating commands. Codex PR 3 pass 16: the
# previous check was vacuous (just `grep --no-session-sync` against
# the whole file). Tighten to require that render_journal_body uses
# the dedicated lookup helper.
check_present "render_journal_body uses _journal_latest_on_date helper" \
  '_journal_latest_on_date' "bin/render-artifact.sh"
# And per-phase resolution still uses --no-session-sync.
check_present "phase resolution uses --no-session-sync" \
  '\-\-no-session-sync' "bin/render-artifact.sh"

# 13. PR 3: stack renderer must validate the stack name before
# touching disk. Restrict to alnum, _, -.
check_present "stack name validation rejects path traversal" \
  '\[!a-zA-Z0-9_-\]\*' "bin/render-artifact.sh"

# 14. PR 3: journal --date must be regex-validated, never piped to a
# shell with metacharacters.
check_present "journal --date YYYY-MM-DD regex" \
  '\[0-9\]\[0-9\]\[0-9\]\[0-9\]-\[0-9\]\[0-9\]-\[0-9\]\[0-9\]' "bin/render-artifact.sh"

# 15. PR 3: SVG must not contain external image hrefs.
check_absent "no SVG <image href" \
  '<image[[:space:]]+href' "bin/render-artifact.sh" "bin/lib/visual-render.sh"

# 16. PR 3: SVG must not embed <foreignObject> (allows arbitrary HTML
# inside SVG which sidesteps the CSP and escape contract).
check_absent "no SVG <foreignObject" \
  '<foreignObject' "bin/render-artifact.sh" "bin/lib/visual-render.sh"

TOTAL=$((PASS+FAIL))
printf "\n  %s/%s checks passed\n" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  printf "${RED}=== %s checks failed ===${NC}\n" "$FAIL"
  exit 1
fi
printf "${GREEN}=== all checks passed ===${NC}\n"
