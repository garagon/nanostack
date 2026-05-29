# interactive.sh — sourced by ci/e2e-visual-artifacts.sh (Harness vNext PR 4 split).
# Cell bodies only; shared helpers/fixtures + summary live in the driver.

# ─── Cell 23d: --interactive emits copy buttons (PR 4) ──────
printf "\n  ${DIM}Cell 23d: --interactive emits copy buttons (PR 4)${NC}\n"
PROJ="$TMP_ROOT/cell23d"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --interactive)
assert_true "interactive plan html exists" test -f "$HTML"
assert_contains "interactive plan has copy-actions section" "$HTML" 'data-testid="copy-actions"'
assert_contains "interactive plan has data-interactive=1" "$HTML" 'data-interactive="1"'
assert_contains "interactive plan has copy-prompt button" "$HTML" 'data-payload-id="copy-prompt"'
assert_contains "interactive plan has copy-markdown button" "$HTML" 'data-payload-id="copy-markdown"'
assert_contains "interactive plan has copy-json button" "$HTML" 'data-payload-id="copy-json"'
assert_contains "interactive plan has copy-status target" "$HTML" 'data-testid="copy-status"'
assert_contains "interactive plan has manual-copy <pre> for prompt" "$HTML" 'data-testid="copy-prompt-pre"'
assert_contains "interactive plan uses navigator.clipboard.writeText" "$HTML" 'navigator.clipboard.writeText'
# Capture the interactive manifest BEFORE the static render so a
# later mtime sort cannot pick the wrong one.
MFST_I=$(ls -t "$NANOSTACK_STORE/visual/manifests/"*plan*.manifest.json | head -1)
assert_true "interactive manifest records interactive: true" \
  sh -c "[ \"\$(jq -r .interactive '$MFST_I')\" = 'true' ]"
# Without --interactive, NO copy section.
HTML_S=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest)
assert_not_contains "static plan has NO copy-actions" "$HTML_S" 'data-testid="copy-actions"'
assert_not_contains "static CSP does NOT allow script-src" "$HTML_S" "script-src 'unsafe-inline'"

# ─── Cell 23e: --interactive CSP allows inline script (PR 4) ─
printf "\n  ${DIM}Cell 23e: interactive CSP (PR 4)${NC}\n"
PROJ="$TMP_ROOT/cell23e"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --interactive)
assert_contains "interactive CSP includes script-src 'unsafe-inline'" "$HTML" "script-src 'unsafe-inline'"
assert_contains "interactive CSP still locks default-src 'none'" "$HTML" "default-src 'none'"
assert_contains "interactive CSP still locks form-action 'none'" "$HTML" "form-action 'none'"
# Static still has the tighter CSP.
HTML_S=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest)
assert_not_contains "static CSP has NO script-src directive" "$HTML_S" "script-src"

# ─── Cell 23f: interactive output is forbidden-API free (PR 4) ─
printf "\n  ${DIM}Cell 23f: forbidden APIs absent from interactive output (PR 4)${NC}\n"
PROJ="$TMP_ROOT/cell23f"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_review "$NANOSTACK_STORE")
HTML_P=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --interactive)
HTML_R=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" review --latest --interactive)
for h in "$HTML_P" "$HTML_R"; do
  assert_not_contains "no fetch( in $(basename $h)" "$h" "fetch("
  assert_not_contains "no XMLHttpRequest in $(basename $h)" "$h" "XMLHttpRequest"
  assert_not_contains "no sendBeacon in $(basename $h)" "$h" "sendBeacon"
  assert_not_contains "no localStorage in $(basename $h)" "$h" "localStorage"
  assert_not_contains "no sessionStorage in $(basename $h)" "$h" "sessionStorage"
  assert_not_contains "no document.cookie in $(basename $h)" "$h" "document.cookie"
  assert_not_contains "no eval( in $(basename $h)" "$h" "eval("
  assert_not_contains "no new Function in $(basename $h)" "$h" "new Function"
  assert_not_contains "no <form in $(basename $h)" "$h" "<form"
  # Only external URL allowed: github.com PR links (PR 2 ship);
  # otherwise no http(s):// inside script body.
done

# ─── Cell 23g: interactive review has copy buttons (PR 4) ───
printf "\n  ${DIM}Cell 23g: interactive review (PR 4)${NC}\n"
HTML=$HTML_R
assert_contains "interactive review has copy-actions" "$HTML" 'data-testid="copy-actions"'
# Review's prompt payload references review-specific terms.
assert_contains "interactive review prompt mentions findings" "$HTML" 'review findings before /ship'

# ─── Cell 23h: </script> in payload does NOT break out of inline script (PR 4 XSS) ─
printf "\n  ${DIM}Cell 23h: </script> payload XSS containment (PR 4)${NC}\n"
PROJ="$TMP_ROOT/cell23h"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" plan '{
  "phase":"plan",
  "summary":{"goal":"\"</script><script>alert(\"XSS\")</script>","scope":"s","planned_files":["</script>"],"plan_approval":"manual"},
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --interactive)
# The malicious sequence must NOT appear as literal `</script><script>` anywhere.
LIT_COUNT=$(grep -o '</script><script>' "$HTML" | wc -l | tr -d ' ')
assert_true "no raw </script><script> sequence in interactive output" sh -c "[ '$LIT_COUNT' = '0' ]"
# PR 4 pass 3 switched the escape from `<\/` to `<`. Confirm
# the u003c form appears (transformation happened).
assert_contains "encoded u003c form present in output" "$HTML" "u003c"
# Manual copy <pre> is HTML-escaped.
assert_contains "manual-copy <pre> shows escaped tag" "$HTML" '&lt;/script&gt;'

# ─── Cell 23i: --interactive rejected outside plan/review (PR 4 pass 1) ─
printf "\n  ${DIM}Cell 23i: --interactive scope (PR 4 pass 1)${NC}\n"
PROJ="$TMP_ROOT/cell23i"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_security "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_qa "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_ship "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_think "$NANOSTACK_STORE")
assert_exit "security --interactive rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' security --latest --interactive"
assert_exit "qa --interactive rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' qa --latest --interactive"
assert_exit "ship --interactive rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' ship --latest --interactive"
assert_exit "think --interactive rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' think --latest --interactive"
assert_exit "journal --interactive rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today --interactive"
assert_exit "stack --interactive rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack default --interactive"

# ─── Cell 23j: --interactive on schema-warning plan does not crash (PR 4 pass 1) ─
printf "\n  ${DIM}Cell 23j: --interactive on schema-warning plan (PR 4 pass 1)${NC}\n"
PROJ="$TMP_ROOT/cell23j"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/plan"
# Plan with non-string risks (objects) and numeric planned_files.
# Schema validation will fail but the renderer must still produce HTML.
cat > "$NANOSTACK_STORE/plan/$(date -u +%Y%m%d)-120000.json" <<JSON
{
  "phase": "plan",
  "project": "$PROJ",
  "summary": {
    "goal": 42,
    "planned_files": [123, 456],
    "plan_approval": "manual",
    "risks": [{"complicated":true}]
  },
  "context_checkpoint": {"summary": null}
}
JSON
# Render must succeed (exit 0). Without unconditional assertion the
# `|| true` mask would have made the cell silently pass on regressions
# (codex PR 4 pass 2).
set +e
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --interactive 2>&1)
RC=$?
set -e
assert_exit "schema-warning plan with --interactive exits 0" 0 test "$RC" = 0
assert_true "schema-warning plan html path is non-empty" sh -c "[ -n '$HTML' ]"
assert_true "schema-warning plan html file exists" test -f "$HTML"

# ─── Cell 23k: --interactive on schema-warning review does not crash (PR 4 pass 1) ─
printf "\n  ${DIM}Cell 23k: --interactive on schema-warning review (PR 4 pass 1)${NC}\n"
PROJ="$TMP_ROOT/cell23k"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/review"
cat > "$NANOSTACK_STORE/review/$(date -u +%Y%m%d)-120000.json" <<JSON
{
  "phase": "review",
  "project": "$PROJ",
  "summary": {"blocking":"one","should_fix":2,"nitpicks":3,"positive":0},
  "scope_drift": {"status": 42},
  "findings": [{"id":"X","severity":"blocking","description":{"nested":"object"}}],
  "context_checkpoint": {}
}
JSON
# Same unconditional assertion as cell 23j.
set +e
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" review --latest --interactive 2>&1)
RC=$?
set -e
assert_exit "schema-warning review with --interactive exits 0" 0 test "$RC" = 0
assert_true "schema-warning review html path is non-empty" sh -c "[ -n '$HTML' ]"
assert_true "schema-warning review html file exists" test -f "$HTML"

# ─── Cell 23l: <!--<script> in payload neutralized (PR 4 pass 3) ─
printf "\n  ${DIM}Cell 23l: <!--<script> XSS containment (PR 4 pass 3)${NC}\n"
PROJ="$TMP_ROOT/cell23l"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" plan '{
  "phase":"plan",
  "summary":{"goal":"<!--<script>alert(1)</script>","scope":"s","planned_files":[],"plan_approval":"manual"},
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --interactive)
# Extract the inline <script>...</script> block. Match the FIRST
# `<script>` (the renderer's own block) and the FIRST closing tag
# after it.
SCRIPT_BODY=$(awk '
  /^[[:space:]]*<script>/ { in_script=1; next }
  /^[[:space:]]*<\/script>/ { in_script=0 }
  in_script { print }
' "$HTML")
# Forbidden raw HTML sequences inside the inline JS body.
for needle in '<!--' '<script' '</script' '<!CDATA'; do
  if printf '%s' "$SCRIPT_BODY" | grep -qF "$needle"; then
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  script body contains literal %s (HTML parser hazard)\n" "$needle"
  else
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    script body has no literal %s\n" "$needle"
  fi
done
# Encoded form should appear in the file (visible escape sequence).
if grep -qF 'u003c' "$HTML"; then
  PASS=$((PASS+1))
  printf "    ${GREEN}OK${NC}    encoded u003c form present\n"
else
  FAIL=$((FAIL+1))
  printf "    ${RED}FAIL${NC}  encoded u003c form missing\n"
fi

