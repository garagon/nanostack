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
  if grep -nE "$pattern" "${files[@]}" >/dev/null 2>&1; then
    FAIL=$((FAIL+1))
    printf "  ${RED}FAIL${NC}  %s\n" "$name"
    printf "         ${DIM}pattern: %s${NC}\n" "$pattern"
    grep -nE "$pattern" "${files[@]}" | sed 's/^/         /' || true
  else
    PASS=$((PASS+1))
    printf "  ${GREEN}OK${NC}    %s\n" "$name"
  fi
}

check_present() {
  local name="$1"; local pattern="$2"; shift 2
  local files=("$@")
  if grep -nE "$pattern" "${files[@]}" >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf "  ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "  ${RED}FAIL${NC}  %s (pattern missing)\n" "$name"
    printf "         ${DIM}pattern: %s${NC}\n" "$pattern"
  fi
}

printf "\n${GREEN}=== Visual artifact template safety ===${NC}\n\n"

# 1. No external URLs in renderer source. Comments are allowed for
# contract refs but the contract doc has no URLs either.
check_absent "no http(s) URLs in renderer/templates" \
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

TOTAL=$((PASS+FAIL))
printf "\n  %s/%s checks passed\n" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  printf "${RED}=== %s checks failed ===${NC}\n" "$FAIL"
  exit 1
fi
printf "${GREEN}=== all checks passed ===${NC}\n"
