# trust-and-path-safety.sh — sourced by ci/e2e-visual-artifacts.sh (Harness vNext PR 4 split).
# Cell bodies only; shared helpers/fixtures + summary live in the driver.

# ─── Cell 2: XSS / escape contract ──────────────────────────
printf "\n  ${DIM}Cell 2: XSS / escape contract${NC}\n"
PROJ="$TMP_ROOT/cell2"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_malicious_plan "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest)
assert_not_contains "no raw <script>alert(" "$HTML" "<script>alert("
assert_not_contains "no raw <img src=x onerror" "$HTML" "<img src=x onerror"
assert_contains "escaped &lt;script&gt;" "$HTML" "&lt;script&gt;"
assert_contains "escaped &lt;img" "$HTML" "&lt;img"
assert_contains "escaped &quot;" "$HTML" "&quot;"

# ─── Cell 3: --strict integrity_missing rejection ───────────
printf "\n  ${DIM}Cell 3: --strict integrity_missing rejection${NC}\n"
PROJ="$TMP_ROOT/cell3"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
# Strip .integrity
jq 'del(.integrity)' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "render --strict on integrity_missing exits 3" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --strict"
# Without --strict it should render with the unverified badge
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest 2>/dev/null)
assert_contains "integrity_missing badge unverified" "$HTML" 'data-trust="integrity_missing"'
assert_contains "badge text unverified" "$HTML" '>unverified<'

# ─── Cell 4: integrity_mismatch always fails ────────────────
printf "\n  ${DIM}Cell 4: integrity_mismatch always fails (exit 3)${NC}\n"
PROJ="$TMP_ROOT/cell4"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
# Mutate .summary.goal after save (keeps .integrity but breaks hash)
jq '.summary.goal = "Tampered!"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "render plain on integrity_mismatch exits 3" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest"
assert_exit "render --strict on integrity_mismatch exits 3" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --strict"

# ─── Cell 5: --out path safety ──────────────────────────────
printf "\n  ${DIM}Cell 5: --out path safety${NC}\n"
PROJ="$TMP_ROOT/cell5"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "--out outside visual root exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out /tmp/outside.html"
assert_exit "--out relative path exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out foo.html"
# PR 1 pass 2 regression: --out with .. that escapes visual/ through a
# missing segment must be rejected even though every "existing
# ancestor" lies inside the visual root.
assert_exit "--out with .. escape exits 4 (PR 1 pass 2 regression)" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out '$NANOSTACK_STORE/visual/new/../../outside.html'"
# Confirm the escape did NOT leave a file behind outside visual/.
assert_true "no escaped file at .nanostack/outside.html" sh -c "[ ! -f '$NANOSTACK_STORE/outside.html' ]"
# Inside the visual root should work.
INSIDE="$NANOSTACK_STORE/visual/plan/explicit.html"
mkdir -p "$(dirname "$INSIDE")"
assert_exit "--out inside visual root succeeds" 0 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out '$INSIDE'"
assert_true "explicit out file exists" test -f "$INSIDE"

# ─── Cell 16: /ship malicious PR URL refused as link ────────
printf "\n  ${DIM}Cell 16: /ship malicious PR URL${NC}\n"
PROJ="$TMP_ROOT/cell16"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_ship_malicious_url "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" ship --latest)
assert_contains "ship unsafe URL marker" "$HTML" 'data-testid="unsafe-pr-url"'
assert_not_contains "ship NO javascript: href" "$HTML" 'href="javascript:'
assert_not_contains "ship NO active <a> for javascript scheme" "$HTML" 'href="javascript'
assert_contains "ship escapes title XSS" "$HTML" '&lt;script&gt;evil&lt;/script&gt;'
assert_not_contains "ship NO raw <script>evil" "$HTML" '<script>evil'

# ─── Cell 17: XSS across all 5 new phases ──────────────────
printf "\n  ${DIM}Cell 17: XSS escape across core phases${NC}\n"
PROJ="$TMP_ROOT/cell17"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# Malicious think
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" think '{
  "phase":"think",
  "summary":{"value_proposition":"<script>alert(1)</script>","scope_mode":"<img src=x onerror=alert(1)>","target_user":"a","narrowest_wedge":"b","key_risk":"c","premise_validated":true},
  "context_checkpoint":{"summary":"\"><iframe>x</iframe>","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" think --latest)
assert_not_contains "think no raw <script>alert" "$HTML" '<script>alert'
assert_not_contains "think no raw <iframe>x" "$HTML" '<iframe>x</iframe>'
assert_contains "think escapes script tag" "$HTML" '&lt;script&gt;'

# Malicious review (finding description contains JS)
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" review '{
  "phase":"review","summary":{"blocking":1,"should_fix":0,"nitpicks":0,"positive":0},
  "scope_drift":{"status":"clean","planned_files":[],"actual_files":[],"out_of_scope_files":[],"missing_files":[]},
  "findings":[{"id":"REV-X","severity":"blocking","description":"<script>alert(\"rev\")</script>","file":"a","line":1}],
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" review --latest)
assert_not_contains "review no raw <script>alert" "$HTML" '<script>alert'
assert_contains "review escapes" "$HTML" '&lt;script&gt;'

# Malicious security proof_of_concept (must escape inside <pre>)
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" security '{
  "phase":"security","summary":{"critical":1,"high":0,"medium":0,"low":0,"total_findings":1},
  "findings":[{"id":"SEC-X","severity":"critical","category":"A01","description":"d","file":"f","line":1,"proof_of_concept":"<script>alert(\"poc\")</script>","fix":"<img src=x onerror=alert(1)>"}],
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" security --latest)
assert_not_contains "security PoC no raw <script>alert" "$HTML" '<script>alert'
assert_not_contains "security fix no raw <img" "$HTML" '<img src=x onerror=alert(1)>'
assert_contains "security PoC escaped" "$HTML" '&lt;script&gt;'
assert_contains "security PoC stays in <pre>" "$HTML" '<details><summary>Proof of concept</summary><pre>'

# Malicious ship.ci_passed (PR 2 pass 1 regression: ci_passed was
# interpolated unescaped because the schema documents it as a
# boolean; a malformed artifact stored it as a string).
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" ship '{
  "phase":"ship",
  "summary":{"pr_number":1,"pr_url":"https://github.com/x/y/pull/1","title":"t","status":"created","ci_passed":"<script>alert(\"ci\")</script>"},
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" ship --latest)
assert_not_contains "ship ci_passed no raw script" "$HTML" '<script>alert("ci")</script>'
assert_contains "ship ci_passed escaped" "$HTML" '&lt;script&gt;alert(&quot;ci&quot;)&lt;/script&gt;'

# Malicious qa (reproduce + root_cause)
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" qa '{
  "phase":"qa","summary":{"mode":"browser","status":"fail","tests_run":1,"tests_passed":0,"tests_failed":1,"bugs_found":1,"bugs_fixed":0},
  "findings":[{"id":"QA-X","severity":"high","description":"d","reproduce":"<script>alert(\"qa\")</script>","root_cause":"<img onerror=alert(1)>","fixed":false}],
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" qa --latest)
assert_not_contains "qa reproduce no raw script" "$HTML" '<script>alert("qa")'
assert_not_contains "qa root_cause no raw img" "$HTML" '<img onerror=alert(1)>'

# ─── Cell 22f: scratch dir does not leak (PR 3 pass 2) ──────
printf "\n  ${DIM}Cell 22f: scratch dir cleanup (PR 3 pass 2)${NC}\n"
PROJ="$TMP_ROOT/cell22f"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
SCRATCH_BEFORE=$(find /tmp -maxdepth 1 -name "render-artifact.*" -type d 2>/dev/null | wc -l | tr -d ' ')
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
SCRATCH_AFTER=$(find /tmp -maxdepth 1 -name "render-artifact.*" -type d 2>/dev/null | wc -l | tr -d ' ')
assert_true "no scratch dir leak across renders" sh -c "[ '$SCRATCH_AFTER' = '$SCRATCH_BEFORE' ]"

# ─── Cell 22j: symlinked visual/stack rejected without leak (PR 3 pass 4) ─
printf "\n  ${DIM}Cell 22j: symlinked visual/stack rejected (PR 3 pass 4)${NC}\n"
PROJ="$TMP_ROOT/cell22j"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual"
mkdir -p "$TMP_ROOT/cell22j-outside"
ln -s "$TMP_ROOT/cell22j-outside" "$NANOSTACK_STORE/visual/stack"
assert_exit "stack with symlinked visual/stack exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack compliance-release"
# No directory was created at the symlink target.
LEAK=$(find "$TMP_ROOT/cell22j-outside" -maxdepth 1 -type d -name "compliance-release" 2>/dev/null | wc -l | tr -d ' ')
assert_true "no directory leaked through symlinked visual/stack" sh -c "[ '$LEAK' = '0' ]"

# Same for visual/journal symlink.
PROJ="$TMP_ROOT/cell22k"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual"
mkdir -p "$TMP_ROOT/cell22k-outside"
ln -s "$TMP_ROOT/cell22k-outside" "$NANOSTACK_STORE/visual/journal"
assert_exit "journal with symlinked visual/journal exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today"

# ─── Cell 22m: tampered .project surfaces as integrity_mismatch (PR 3 pass 5) ─
printf "\n  ${DIM}Cell 22m: tampered .project surfaces (PR 3 pass 5)${NC}\n"
PROJ="$TMP_ROOT/cell22m"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
# Tamper .project. The integrity hash now mismatches but the project
# filter would otherwise drop this file.
jq '.project = "/other"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_contains "tampered .project surfaces as integrity_mismatch row" "$HTML" 'data-trust="integrity_mismatch"'
# --strict must now fail.
assert_exit "journal --strict catches tampered .project" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today --strict"

# ─── Cell 22q: integrity_missing + .project flip caught (PR 3 pass 7) ─
printf "\n  ${DIM}Cell 22q: integrity_missing + .project flip (PR 3 pass 7)${NC}\n"
PROJ="$TMP_ROOT/cell22q"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
# Strip .integrity AND flip .project.
jq 'del(.integrity) | .project = "/other"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_contains "journal surfaces .integrity-strip + .project-flip" "$HTML" 'data-trust="integrity_missing"'
assert_exit "journal --strict catches integrity_missing + .project flip" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today --strict"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
assert_contains "stack surfaces .integrity-strip + .project-flip" "$HTML" 'data-phase="plan" data-trust="integrity_missing"'
assert_exit "stack --strict catches integrity_missing + .project flip" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack compliance-release --strict"

# ─── Cell 9a: --out works on fresh store (PR 1 pass 1 regression) ─
printf "\n  ${DIM}Cell 9a: --out on fresh store (PR 1 pass 1 regression)${NC}\n"
PROJ="$TMP_ROOT/cell9a"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Visual root does not yet exist; --out under it must still succeed.
[ ! -d "$NANOSTACK_STORE/visual" ] && PASS=$((PASS+1)) || PASS=$PASS
TARGET="$NANOSTACK_STORE/visual/plan/custom.html"
set +e
(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --out "$TARGET" >/dev/null 2>&1)
RC=$?
set -e
assert_exit "--out on fresh store succeeds" 0 test "$RC" = 0
assert_true "custom output file exists" test -f "$TARGET"

# ─── Cell 9e: symlinked visual subdirectory rejected ───────
# PR 1 pass 4 regression: a pre-existing symlink under visual/
# (e.g. visual/plan -> /tmp/outside) must be rejected so mv cannot
# write through it.
printf "\n  ${DIM}Cell 9e: symlinked visual subdir (PR 1 pass 4 regression)${NC}\n"
PROJ="$TMP_ROOT/cell9e"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual"
mkdir -p "$TMP_ROOT/cell9e-outside"
ln -s "$TMP_ROOT/cell9e-outside" "$NANOSTACK_STORE/visual/plan"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "symlinked visual/plan exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest"
# Confirm nothing was written through the symlink.
HTML_COUNT=$(find "$TMP_ROOT/cell9e-outside" -maxdepth 1 -name "*.html" 2>/dev/null | wc -l | tr -d ' ')
assert_true "no file written through symlinked subdir" sh -c "[ '$HTML_COUNT' = '0' ]"

# Same check for visual/manifests symlink.
PROJ="$TMP_ROOT/cell9f"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual"
mkdir -p "$TMP_ROOT/cell9f-outside"
ln -s "$TMP_ROOT/cell9f-outside" "$NANOSTACK_STORE/visual/manifests"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "symlinked visual/manifests exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest"
MFST_COUNT=$(find "$TMP_ROOT/cell9f-outside" -maxdepth 1 -name "*.manifest.json" 2>/dev/null | wc -l | tr -d ' ')
assert_true "no manifest written through symlinked subdir" sh -c "[ '$MFST_COUNT' = '0' ]"

# ─── Cell 9g: symlinked output leaf rejected ───────────────
# PR 1 pass 5 regression: an --out whose leaf component is a
# pre-existing symlink to a directory must be rejected. Otherwise
# atomic mv would move the temp file INTO the symlink target.
printf "\n  ${DIM}Cell 9g: symlinked output leaf (PR 1 pass 5 regression)${NC}\n"
PROJ="$TMP_ROOT/cell9g"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual/plan"
mkdir -p "$TMP_ROOT/cell9g-outside"
ln -s "$TMP_ROOT/cell9g-outside" "$NANOSTACK_STORE/visual/plan/explicit.html"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "symlinked output leaf exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out '$NANOSTACK_STORE/visual/plan/explicit.html'"
LEAK_COUNT=$(find "$TMP_ROOT/cell9g-outside" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
assert_true "no file leaked through symlinked leaf" sh -c "[ '$LEAK_COUNT' = '0' ]"

# A leaf that is already a directory must also be rejected so the
# mv doesn't move the temp file INTO the directory.
PROJ="$TMP_ROOT/cell9h"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual/plan/explicit.html"  # leaf is a directory
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "directory at output leaf exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out '$NANOSTACK_STORE/visual/plan/explicit.html'"

# ─── Cell 9i: symlink + .. bypass through write target ─────
# PR 1 pass 6 P1 regression: --out with a symlinked component
# followed by `..`. Lexical normalization passed before; the kernel
# would resolve the original path at write time and escape visual/.
# The fix is to write to the normalized path.
printf "\n  ${DIM}Cell 9i: symlink + .. bypass through write (PR 1 pass 6)${NC}\n"
PROJ="$TMP_ROOT/cell9i"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual/plan"
mkdir -p "$TMP_ROOT/cell9i-outside"
ln -s "$TMP_ROOT/cell9i-outside" "$NANOSTACK_STORE/visual/link"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Attack: visual/link/../evil.html. Normalized this is visual/evil.html
# (under visual/). At kernel-resolve time the original path goes:
# visual/link -> /tmp/.../cell9i-outside, then .. -> /tmp/.../, then
# evil.html appears outside the store.
set +e
(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --out \
  "$NANOSTACK_STORE/visual/link/../evil.html" >/dev/null 2>&1)
RC=$?
set -e
# Either the render exits 4 (rejected), or it succeeds writing
# safely to visual/evil.html under the normalized path. Both are
# acceptable; what is NOT acceptable is a file appearing outside
# visual/.
LEAK_COUNT=$(find "$TMP_ROOT/cell9i-outside" -maxdepth 1 -type f -name "*.html" 2>/dev/null | wc -l | tr -d ' ')
STORE_LEAK=$(find "$PROJ" -maxdepth 3 -name 'evil.html' -not -path "*/visual/*" 2>/dev/null | wc -l | tr -d ' ')
assert_true "no file outside visual via symlink+.. (outside dir empty)" sh -c "[ '$LEAK_COUNT' = '0' ]"
assert_true "no file at evil.html outside visual/" sh -c "[ '$STORE_LEAK' = '0' ]"

# ─── Cell 9m: glob metachars in --out preserved literally ──
# PR 1 pass 8 P3 regression. nano_visual_normalize_path used to
# perform pathname expansion during the IFS split; an --out with `*`
# or `?` could be silently rewritten to a matching real filename.
printf "\n  ${DIM}Cell 9m: glob metachars in --out (PR 1 pass 8)${NC}\n"
PROJ="$TMP_ROOT/cell9m"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual/plan"
# Pre-create a real file that would match a glob if expansion ran.
touch "$NANOSTACK_STORE/visual/plan/starA.html"
touch "$NANOSTACK_STORE/visual/plan/starB.html"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Use a quoted literal "star*.html" as --out; this must NOT expand.
TARGET="$NANOSTACK_STORE/visual/plan/star?special.html"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --out "$TARGET")
assert_true "literal glob path preserved (no expansion)" \
  sh -c "[ '$HTML' = '$TARGET' ]"
assert_true "literal file exists at requested path" test -f "$TARGET"

# ─── Cell 9: symlinked visual root rejected ─────────────────
printf "\n  ${DIM}Cell 9: symlinked visual root rejected${NC}\n"
PROJ="$TMP_ROOT/cell9"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
mkdir -p "$TMP_ROOT/cell9-elsewhere"
ln -s "$TMP_ROOT/cell9-elsewhere" "$NANOSTACK_STORE/visual"
assert_exit "symlinked visual root exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest"

