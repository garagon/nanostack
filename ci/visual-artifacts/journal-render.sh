# journal-render.sh — sourced by ci/e2e-visual-artifacts.sh (Harness vNext PR 4 split).
# Cell bodies only; shared helpers/fixtures + summary live in the driver.

# ─── Cell 18: sprint journal view ───────────────────────────
printf "\n  ${DIM}Cell 18: sprint journal view${NC}\n"
PROJ="$TMP_ROOT/cell18"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_think "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_review "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_security "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_qa "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_ship "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_true "journal html exists" test -f "$HTML"
assert_contains "journal page title" "$HTML" "Sprint journal"
assert_contains "journal data-phase=journal" "$HTML" 'data-phase="journal"'
assert_contains "journal timeline" "$HTML" "Phase timeline"
assert_contains "journal think row" "$HTML" 'data-phase="think"'
assert_contains "journal plan row" "$HTML" 'data-phase="plan"'
assert_contains "journal review row" "$HTML" 'data-phase="review"'
assert_contains "journal security row" "$HTML" 'data-phase="security"'
assert_contains "journal qa row" "$HTML" 'data-phase="qa"'
assert_contains "journal ship row" "$HTML" 'data-phase="ship"'
# Manifest must list every source.
MFST=$(ls "$NANOSTACK_STORE/visual/manifests/"*journal*.manifest.json | head -1)
assert_true "journal manifest kind = journal" sh -c "[ \"\$(jq -r .kind '$MFST')\" = 'journal' ]"
assert_true "journal sources length >= 6" sh -c "[ \"\$(jq -r '.source_artifacts | length' '$MFST')\" -ge 6 ]"
# Trust badge aggregated.
assert_contains "journal aggregated badge" "$HTML" 'data-trust="not_applicable"'
assert_contains "journal aggregated badge text" "$HTML" '>aggregated<'

# ─── Cell 19: journal flags missing/tampered phases ──────────
printf "\n  ${DIM}Cell 19: journal flags missing/tampered${NC}\n"
PROJ="$TMP_ROOT/cell19"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# Save only think + plan; review/security/qa/ship will be missing.
(cd "$PROJ" && save_valid_think "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_contains "journal renders missing phases" "$HTML" "No artifact found"
# Tamper with plan; the row must show 'tampered'.
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
jq '.summary.goal = "Tampered"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_contains "journal flags tampered" "$HTML" '>tampered<'
# Per-row trust attribute present for the tampered row.
assert_contains "journal plan row data-trust" "$HTML" 'data-phase="plan" data-trust="integrity_mismatch"'

# ─── Cell 22: journal --date validation ────────────────────
printf "\n  ${DIM}Cell 22: journal --date validation${NC}\n"
PROJ="$TMP_ROOT/cell22"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "journal --date bad shape exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --date 2026/05/11"
assert_exit "journal --date with shell metachars exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --date '2026-05-11; rm -rf x'"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --date 2026-05-11)
assert_true "journal --date valid shape works" test -f "$HTML"

# ─── Cell 22a: --date filters by date, not last 30 days (PR 3 pass 1) ─
printf "\n  ${DIM}Cell 22a: journal --date filter (PR 3 pass 1)${NC}\n"
PROJ="$TMP_ROOT/cell22a"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Rename today's artifact to look like it was saved on 2026-05-09.
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
NEW="$NANOSTACK_STORE/plan/20260509-100000.json"
jq '.timestamp = "2026-05-09T10:00:00Z"' "$PLAN_PATH" > "$NEW"
rm "$PLAN_PATH"
# Now request the journal for 2026-05-09; the plan artifact must appear.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --date 2026-05-09)
assert_contains "journal --date 2026-05-09 shows the dated plan" "$HTML" "20260509-100000.json"
# Request another date with no artifacts; plan must show as missing.
HTML2=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --date 2026-05-08)
assert_contains "journal --date 2026-05-08 says missing" "$HTML2" "No artifact found"
assert_not_contains "journal 2026-05-08 does NOT show 2026-05-09 plan path" "$HTML2" "20260509-100000.json"

# ─── Cell 22d: bare `journal` defaults to today (PR 3 pass 2) ───
printf "\n  ${DIM}Cell 22d: bare journal defaults to today (PR 3 pass 2)${NC}\n"
PROJ="$TMP_ROOT/cell22d"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal)
TODAY=$(date -u +%Y-%m-%d)
assert_contains "bare journal renders today's date" "$HTML" "$TODAY"
# Filename must not contain a trailing dash.
case "$HTML" in
  *journal-.html|*journal-*.html) ;;
  *)
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    bare journal filename has no stray dash\n"
    ;;
esac
case "$HTML" in
  *journal-.html)
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  bare journal filename has stray dash: %s\n" "$HTML"
    ;;
esac

# ─── Cell 22e: --strict on aggregate fails for missing integrity (PR 3 pass 2) ─
printf "\n  ${DIM}Cell 22e: --strict on aggregate (PR 3 pass 2)${NC}\n"
PROJ="$TMP_ROOT/cell22e"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Strip integrity on plan, then journal --strict must reject.
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
jq 'del(.integrity)' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "journal --strict fails on integrity_missing" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today --strict"
# Tamper plan; --strict must also fail. Delete prior artifact first
# so the latest-picker definitely sees the tampered one.
rm -f "$NANOSTACK_STORE/plan/"*.json
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
jq '.summary.goal = "Tampered"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "journal --strict fails on integrity_mismatch" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today --strict"
# Stack --strict: same.
assert_exit "stack --strict fails when any artifact tampered" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack compliance-release --strict"

# ─── Cell 22h: --manifest-only with --strict still enforces (PR 3 pass 3) ─
printf "\n  ${DIM}Cell 22h: --manifest-only --strict enforces (PR 3 pass 3)${NC}\n"
PROJ="$TMP_ROOT/cell22h"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
jq '.summary.goal = "Tampered"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "journal --strict --manifest-only exits 3 when tampered" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today --strict --manifest-only"
assert_exit "stack --strict --manifest-only exits 3 when tampered" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack compliance-release --strict --manifest-only"

# ─── Cell 22l: --today does not pull stale artifacts (PR 3 pass 4) ─
printf "\n  ${DIM}Cell 22l: --today strict-date filter (PR 3 pass 4)${NC}\n"
PROJ="$TMP_ROOT/cell22l"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/plan"
# Save a plan with yesterday's date.
YEST_DATE=$(date -u -v-1d +%Y%m%d 2>/dev/null || date -u -d "yesterday" +%Y%m%d 2>/dev/null || echo "20260510")
YEST_FILE="$NANOSTACK_STORE/plan/${YEST_DATE}-120000.json"
jq -n --arg p "$PROJ" '{
  schema_version: "1",
  phase: "plan",
  timestamp: "2026-05-10T12:00:00Z",
  project: $p,
  branch: "main",
  summary: {goal:"yesterday", scope:"small", planned_files:[], plan_approval:"manual"},
  context_checkpoint: {summary:"x", key_files:[], decisions_made:[], open_questions:[]}
}' > "$YEST_FILE"
# Render today's journal; plan must show as missing, not yesterday's.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_not_contains "today's journal does not show yesterday's plan" "$HTML" "${YEST_DATE}-120000.json"
# Plan row says missing.
assert_contains "today's journal shows plan as missing" "$HTML" 'data-phase="plan"'

# ─── Cell 22u: malformed same-day artifact does not crash journal (PR 3 pass 9) ─
printf "\n  ${DIM}Cell 22u: malformed same-day artifact (PR 3 pass 9)${NC}\n"
PROJ="$TMP_ROOT/cell22u"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/plan"
# Drop a malformed (truncated) JSON file with today's date prefix.
TODAY_COMPACT=$(date -u +%Y%m%d)
printf '{"phase":"plan","summary":{' > "$NANOSTACK_STORE/plan/${TODAY_COMPACT}-120000.json"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_true "malformed plan artifact does not crash journal" test -f "$HTML"
# The row should surface as unreadable or integrity_missing, not abort.
assert_contains "malformed artifact row appears" "$HTML" 'data-phase="plan"'

# ─── Cell 22x: shared store does not surface other-project tamper (PR 3 pass 13) ─
printf "\n  ${DIM}Cell 22x: shared store project isolation (PR 3 pass 13)${NC}\n"
SHARED_STORE="$TMP_ROOT/cell22x-shared"
mkdir -p "$SHARED_STORE"
# Project A owns the store legitimately.
PROJ_A="$TMP_ROOT/cell22x-projA"
setup_project "$PROJ_A"
(cd "$PROJ_A" && NANOSTACK_STORE="$SHARED_STORE" "$REPO/bin/save-artifact.sh" plan '{
  "phase":"plan",
  "summary":{"goal":"A","scope":"small","planned_files":[],"plan_approval":"manual"},
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
# Some other project also saved here, then tampered. From project B's
# perspective, this is foreign noise.
PROJ_OTHER="$TMP_ROOT/cell22x-other"
setup_project "$PROJ_OTHER"
(cd "$PROJ_OTHER" && NANOSTACK_STORE="$SHARED_STORE" "$REPO/bin/save-artifact.sh" plan '{
  "phase":"plan",
  "summary":{"goal":"OTHER","scope":"small","planned_files":[],"plan_approval":"manual"},
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
OTHER_PLAN=$(ls -t "$SHARED_STORE/plan/"*.json | head -1)
jq 'del(.integrity)' "$OTHER_PLAN" > "$OTHER_PLAN.tmp" && mv "$OTHER_PLAN.tmp" "$OTHER_PLAN"

# Project B renders its own journal against the shared store. It is
# NOT the same git-root, so the store is "shared" from B's view.
PROJ_B="$TMP_ROOT/cell22x-projB"
setup_project "$PROJ_B"
export NANOSTACK_STORE="$SHARED_STORE"
HTML=$(cd "$PROJ_B" && "$REPO/bin/render-artifact.sh" journal --today)
# Project B has no plan; the row should say missing, NOT surface the
# OTHER project's tampered plan.
assert_contains "B's journal shows plan as missing" "$HTML" "No artifact found"
assert_not_contains "B's journal does NOT surface OTHER project's tampered plan" "$HTML" "OTHER"
# Strict must also pass (no tampered source attributed to B).
assert_exit "B's journal --strict succeeds despite shared-store tamper" 0 \
  sh -c "cd '$PROJ_B' && '$REPO/bin/render-artifact.sh' journal --today --strict"
unset NANOSTACK_STORE

