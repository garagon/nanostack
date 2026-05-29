# stack-render.sh — sourced by ci/e2e-visual-artifacts.sh (Harness vNext PR 4 split).
# Cell bodies only; shared helpers/fixtures + summary live in the driver.

# ─── Cell 20: custom stack DAG view (compliance-release) ─────
printf "\n  ${DIM}Cell 20: stack compliance-release DAG${NC}\n"
PROJ="$TMP_ROOT/cell20"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
assert_true "stack html exists" test -f "$HTML"
assert_contains "stack title" "$HTML" "Custom stack"
assert_contains "stack display_name" "$HTML" "Compliance Release Stack"
assert_contains "stack SVG opens" "$HTML" "<svg"
assert_contains "stack SVG closes" "$HTML" "</svg>"
# All 10 expected phases must appear as table rows.
for ph in think plan build review qa security license-audit privacy-check release-readiness ship; do
  assert_contains "stack table row $ph" "$HTML" "data-phase=\"$ph\""
done
# Missing phases must render as 'missing'.
assert_contains "stack missing badge" "$HTML" ">missing<"
# No certification language.
assert_not_contains "stack no certification language" "$HTML" 'certified'
assert_not_contains "stack no compliance language" "$HTML" 'compliant'

# ─── Cell 21: stack name validation ─────────────────────────
printf "\n  ${DIM}Cell 21: stack name validation${NC}\n"
PROJ="$TMP_ROOT/cell21"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# Path traversal in stack name must be rejected.
assert_exit "stack name with .. rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack ../etc"
assert_exit "stack name with / rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack a/b"
assert_exit "stack name with space rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack 'foo bar'"

# Unknown stack: graceful "not found", not crash.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack does-not-exist 2>/dev/null || true)
# When no stack file matches and no config.json exists, default graph
# applies (the registry returns the built-in sprint).
[ -n "$HTML" ] && assert_true "stack fallback to default registry produced HTML" test -f "$HTML"

# ─── Cell 22b: stack falls back to project phase_graph (PR 3 pass 1) ─
printf "\n  ${DIM}Cell 22b: stack falls back to project phase_graph (PR 3 pass 1)${NC}\n"
PROJ="$TMP_ROOT/cell22b"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
cat > "$NANOSTACK_STORE/config.json" <<'CFG'
{
  "schema_version": "1",
  "custom_phases": ["license-audit"],
  "phase_graph": [
    {"name": "think", "depends_on": []},
    {"name": "plan", "depends_on": ["think"]},
    {"name": "build", "depends_on": ["plan"]},
    {"name": "review", "depends_on": ["build"]},
    {"name": "license-audit", "depends_on": ["build"]},
    {"name": "ship", "depends_on": ["review", "license-audit"]}
  ]
}
CFG
# No stack file under examples or stacks/; the fallback to the
# project's phase_graph (registry) only kicks in for `stack default`
# (PR 3 pass 12).
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack default)
assert_true "stack from project graph renders" test -f "$HTML"
assert_contains "stack shows the custom phase license-audit" "$HTML" 'data-phase="license-audit"'
assert_contains "stack shows SVG" "$HTML" "<svg"

# ─── Cell 22g: stack manifest with backslash path (PR 3 pass 2) ─
printf "\n  ${DIM}Cell 22g: stack manifest JSON escape (PR 3 pass 2)${NC}\n"
PROJ="$TMP_ROOT/cell22g"
setup_project "$PROJ"
# A project path containing a backslash is rare but the renderer
# should never produce invalid JSON. Validate by rendering with the
# normal path and confirming the manifest parses cleanly.
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
MFST=$(ls "$NANOSTACK_STORE/visual/manifests/"*stack*.manifest.json | head -1)
assert_true "stack manifest is parseable JSON" jq -e '.' "$MFST"
assert_true "stack manifest has source_artifacts array" \
  sh -c "[ \"\$(jq -r 'type' '$MFST')\" = 'object' ] && [ \"\$(jq -r '.source_artifacts | type' '$MFST')\" = 'array' ]"

# ─── Cell 22i: large unsorted phase_graph renders every node (PR 3 pass 3) ─
printf "\n  ${DIM}Cell 22i: large unsorted phase_graph (PR 3 pass 3)${NC}\n"
PROJ="$TMP_ROOT/cell22i"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# 15-node linear chain in reverse topological order. The previous
# cap of 10 rounds left the tail of the chain out of the SVG.
cat > "$NANOSTACK_STORE/config.json" <<'CFG'
{
  "schema_version": "1",
  "custom_phases": ["c1","c2","c3","c4","c5","c6","c7","c8","c9","c10","c11","c12","c13"],
  "phase_graph": [
    {"name": "c13", "depends_on": ["c12"]},
    {"name": "c12", "depends_on": ["c11"]},
    {"name": "c11", "depends_on": ["c10"]},
    {"name": "c10", "depends_on": ["c9"]},
    {"name": "c9", "depends_on": ["c8"]},
    {"name": "c8", "depends_on": ["c7"]},
    {"name": "c7", "depends_on": ["c6"]},
    {"name": "c6", "depends_on": ["c5"]},
    {"name": "c5", "depends_on": ["c4"]},
    {"name": "c4", "depends_on": ["c3"]},
    {"name": "c3", "depends_on": ["c2"]},
    {"name": "c2", "depends_on": ["c1"]},
    {"name": "c1", "depends_on": []}
  ]
}
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack default)
# Every node must appear in the SVG (as a <g data-phase=...> wrapper).
for n in c1 c5 c10 c13; do
  assert_contains "stack svg contains $n" "$HTML" "data-phase=\"$n\""
done

# ─── Cell 22n: malformed stack phase_graph renders graceful notice (PR 3 pass 5) ─
printf "\n  ${DIM}Cell 22n: malformed stack graph (PR 3 pass 5)${NC}\n"
PROJ="$TMP_ROOT/cell22n"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/stacks/badstack"
cat > "$NANOSTACK_STORE/stacks/badstack/stack.json" <<'CFG'
{
  "schema_version": "1",
  "name": "badstack",
  "phase_graph": "this should be an array, not a string"
}
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack badstack 2>/dev/null || true)
# The render returns 0 because the contract is to render gracefully.
assert_true "malformed stack still produces HTML" test -f "${HTML:-/dev/null}"
[ -f "${HTML:-/dev/null}" ] && {
  assert_contains "stack invalid notice rendered" "$HTML" "Stack invalid"
}

# Array of scalars (not objects).
mkdir -p "$NANOSTACK_STORE/stacks/badstack2"
cat > "$NANOSTACK_STORE/stacks/badstack2/stack.json" <<'CFG'
{
  "schema_version": "1",
  "name": "badstack2",
  "phase_graph": ["just", "strings", "not", "objects"]
}
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack badstack2 2>/dev/null || true)
[ -f "${HTML:-/dev/null}" ] && {
  assert_contains "scalar-array stack also invalid" "$HTML" "Stack invalid"
}

# ─── Cell 22o: stack --strict surfaces tampered .project (PR 3 pass 6) ─
printf "\n  ${DIM}Cell 22o: stack --strict surfaces tampered .project (PR 3 pass 6)${NC}\n"
PROJ="$TMP_ROOT/cell22o"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
jq '.project = "/other-project"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "stack --strict catches tampered .project" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack compliance-release --strict"
# Without --strict, the row must show data-trust=integrity_mismatch.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
assert_contains "stack table shows tampered .project as integrity_mismatch" "$HTML" 'data-phase="plan" data-trust="integrity_mismatch"'

# ─── Cell 22p: stricter graph validation (PR 3 pass 6) ──────
printf "\n  ${DIM}Cell 22p: strict graph validation (PR 3 pass 6)${NC}\n"
PROJ="$TMP_ROOT/cell22p"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"

# depends_on as a string (not array).
mkdir -p "$NANOSTACK_STORE/stacks/bad_deps"
cat > "$NANOSTACK_STORE/stacks/bad_deps/stack.json" <<'CFG'
{ "schema_version":"1", "name":"bad_deps",
  "phase_graph": [ {"name":"a","depends_on":"not-array"} ] }
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack bad_deps)
assert_contains "depends_on string rejected with invalid notice" "$HTML" "Stack invalid"

# Empty array.
mkdir -p "$NANOSTACK_STORE/stacks/empty_graph"
cat > "$NANOSTACK_STORE/stacks/empty_graph/stack.json" <<'CFG'
{ "schema_version":"1", "name":"empty_graph", "phase_graph": [] }
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack empty_graph)
assert_contains "empty phase_graph rejected" "$HTML" "non-empty array"

# Dangling dependency.
mkdir -p "$NANOSTACK_STORE/stacks/dangling"
cat > "$NANOSTACK_STORE/stacks/dangling/stack.json" <<'CFG'
{ "schema_version":"1", "name":"dangling",
  "phase_graph": [
    {"name":"a","depends_on":[]},
    {"name":"b","depends_on":["nonexistent"]}
  ] }
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack dangling)
assert_contains "dangling dependency rejected" "$HTML" "dangling dependency"

# Empty name string.
mkdir -p "$NANOSTACK_STORE/stacks/empty_name"
cat > "$NANOSTACK_STORE/stacks/empty_name/stack.json" <<'CFG'
{ "schema_version":"1", "name":"empty_name",
  "phase_graph": [ {"name":"","depends_on":[]} ] }
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack empty_name)
assert_contains "empty name rejected" "$HTML" "Stack invalid"

# ─── Cell 22r: cyclic phase_graph rejected (PR 3 pass 7) ────
printf "\n  ${DIM}Cell 22r: cyclic phase_graph rejected (PR 3 pass 7)${NC}\n"
PROJ="$TMP_ROOT/cell22r"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"

mkdir -p "$NANOSTACK_STORE/stacks/cycle2"
cat > "$NANOSTACK_STORE/stacks/cycle2/stack.json" <<'CFG'
{ "schema_version":"1", "name":"cycle2",
  "phase_graph": [
    {"name":"a","depends_on":["b"]},
    {"name":"b","depends_on":["a"]}
  ] }
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack cycle2)
assert_contains "2-node cycle rejected" "$HTML" "cycle"

mkdir -p "$NANOSTACK_STORE/stacks/cycle3"
cat > "$NANOSTACK_STORE/stacks/cycle3/stack.json" <<'CFG'
{ "schema_version":"1", "name":"cycle3",
  "phase_graph": [
    {"name":"a","depends_on":["c"]},
    {"name":"b","depends_on":["a"]},
    {"name":"c","depends_on":["b"]}
  ] }
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack cycle3)
assert_contains "3-node cycle rejected" "$HTML" "cycle"

mkdir -p "$NANOSTACK_STORE/stacks/self_cycle"
cat > "$NANOSTACK_STORE/stacks/self_cycle/stack.json" <<'CFG'
{ "schema_version":"1", "name":"self_cycle",
  "phase_graph": [
    {"name":"a","depends_on":["a"]}
  ] }
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack self_cycle)
assert_contains "self-cycle rejected" "$HTML" "cycle"

# ─── Cell 22s: malformed phase names rejected (PR 3 pass 8) ──
printf "\n  ${DIM}Cell 22s: malformed phase names rejected (PR 3 pass 8)${NC}\n"
PROJ="$TMP_ROOT/cell22s"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"

# Whitespace in phase name.
mkdir -p "$NANOSTACK_STORE/stacks/spacename"
cat > "$NANOSTACK_STORE/stacks/spacename/stack.json" <<'CFG'
{ "schema_version":"1", "name":"spacename",
  "phase_graph": [
    {"name":"license audit","depends_on":[]}
  ] }
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack spacename)
assert_contains "phase name with whitespace rejected" "$HTML" "phase names must match"

# Path separator in phase name.
mkdir -p "$NANOSTACK_STORE/stacks/slashname"
cat > "$NANOSTACK_STORE/stacks/slashname/stack.json" <<'CFG'
{ "schema_version":"1", "name":"slashname",
  "phase_graph": [
    {"name":"bad/name","depends_on":[]}
  ] }
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack slashname)
assert_contains "phase name with slash rejected" "$HTML" "phase names must match"

# Duplicate names.
mkdir -p "$NANOSTACK_STORE/stacks/dup"
cat > "$NANOSTACK_STORE/stacks/dup/stack.json" <<'CFG'
{ "schema_version":"1", "name":"dup",
  "phase_graph": [
    {"name":"plan","depends_on":[]},
    {"name":"plan","depends_on":[]}
  ] }
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack dup)
assert_contains "duplicate phase names rejected" "$HTML" "duplicate node names"

# ─── Cell 22t: malformed stack metadata does not crash and does not fall back (PR 3 pass 9+10) ─
printf "\n  ${DIM}Cell 22t: malformed stack metadata (PR 3 pass 9+10)${NC}\n"
PROJ="$TMP_ROOT/cell22t"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/stacks/badjson"
# Truncated JSON in stack.json.
printf '{"name":"badjson","phase_graph":[' > "$NANOSTACK_STORE/stacks/badjson/stack.json"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack badjson)
assert_true "malformed stack JSON renders an HTML page" test -f "$HTML"
# PR 3 pass 10: do not silently fall back to the project graph; emit
# a Stack invalid notice instead so the broken definition is visible.
assert_contains "named-but-malformed stack -> Stack invalid notice" "$HTML" "Stack invalid"
assert_not_contains "named-but-malformed stack does NOT render default phases" "$HTML" 'data-phase="think"'

# ─── Cell 22v: stack survives truncated phase artifact (PR 3 pass 11) ─
printf "\n  ${DIM}Cell 22v: stack survives truncated artifact (PR 3 pass 11)${NC}\n"
PROJ="$TMP_ROOT/cell22v"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/plan"
# Truncated plan artifact.
printf '{"phase":"plan","summary":{' > "$NANOSTACK_STORE/plan/$(date -u +%Y%m%d)-100000.json"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
assert_true "stack html exists despite truncated artifact" test -f "$HTML"
# The plan row in the table surfaces as integrity_missing (not a crash).
assert_contains "stack table shows plan as integrity_missing" "$HTML" 'data-phase="plan" data-trust="integrity_missing"'
# --strict catches it.
assert_exit "stack --strict catches truncated artifact" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack compliance-release --strict"

# ─── Cell 22w: typo stack name -> Stack not found (PR 3 pass 12) ─
printf "\n  ${DIM}Cell 22w: typo stack name (PR 3 pass 12)${NC}\n"
PROJ="$TMP_ROOT/cell22w"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# No stack file for "compliance-relase" (typo of "compliance-release").
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-relase)
assert_true "typo stack still produces HTML" test -f "$HTML"
assert_contains "typo stack shows Stack not found" "$HTML" "Stack not found"
assert_not_contains "typo stack does NOT render default phases" "$HTML" 'data-phase="think"'

# Bare `stack default` still falls back to the project graph.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack default)
assert_contains "stack default falls back to project graph" "$HTML" 'data-phase="think"'

# ─── Cell 22y: stack lookup walks past 30 newer foreign artifacts (PR 3 pass 14) ─
printf "\n  ${DIM}Cell 22y: stack lookup uncapped (PR 3 pass 14)${NC}\n"
SHARED_STORE="$TMP_ROOT/cell22y-shared"
mkdir -p "$SHARED_STORE/plan"
# Our project saves a plan FIRST (oldest).
PROJ_OURS="$TMP_ROOT/cell22y-ours"
setup_project "$PROJ_OURS"
(cd "$PROJ_OURS" && NANOSTACK_STORE="$SHARED_STORE" "$REPO/bin/save-artifact.sh" plan '{
  "phase":"plan",
  "summary":{"goal":"OURS","scope":"small","planned_files":[],"plan_approval":"manual"},
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
OUR_PLAN=$(ls "$SHARED_STORE/plan/"*.json | head -1)
OUR_PROJECT=$(jq -r '.project' "$OUR_PLAN")
# Now write 35 newer "other project" artifacts.
PROJ_OTHER="$TMP_ROOT/cell22y-other"
setup_project "$PROJ_OTHER"
sleep 1  # ensure mtime is strictly newer
for i in $(seq 1 35); do
  TS="2026-05-12-$(printf "%06d" $((100000 + i)))"
  cat > "$SHARED_STORE/plan/${TS//-/}.json" <<JSON
{"phase":"plan","project":"/other/$i","timestamp":"$TS","summary":{"goal":"other$i"}}
JSON
done
# Render our project's stack. Without the fix, our plan was beyond
# the 30-candidate cap and the row would render as missing.
export NANOSTACK_STORE="$SHARED_STORE"
HTML=$(cd "$PROJ_OURS" && "$REPO/bin/render-artifact.sh" stack compliance-release)
assert_contains "stack finds OUR plan past 30 newer foreign artifacts" "$HTML" "$OUR_PLAN"
unset NANOSTACK_STORE

# ─── Cell 22z: invalid stack manifest has >= 1 source (PR 3 pass 15) ─
printf "\n  ${DIM}Cell 22z: invalid stack manifest sources (PR 3 pass 15)${NC}\n"
PROJ="$TMP_ROOT/cell22z"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"

# Stack invalid: malformed stack file.
mkdir -p "$NANOSTACK_STORE/stacks/inv_manifest"
printf '{"name":"inv_manifest","phase_graph":[' > "$NANOSTACK_STORE/stacks/inv_manifest/stack.json"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack inv_manifest)
MFST=$(ls "$NANOSTACK_STORE/visual/manifests/"*inv_manifest*.manifest.json | head -1)
LEN=$(jq -r '.source_artifacts | length' "$MFST")
assert_true "invalid-stack manifest has >= 1 source" sh -c "[ '$LEN' -ge 1 ]"
assert_true "invalid-stack source phase begins with stack:" \
  sh -c "jq -re '.source_artifacts[0].phase | startswith(\"stack:\")' '$MFST' >/dev/null"

# Stack not found: typo.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack does_not_exist_typo)
MFST=$(ls "$NANOSTACK_STORE/visual/manifests/"*does_not_exist_typo*.manifest.json | head -1)
LEN=$(jq -r '.source_artifacts | length' "$MFST")
assert_true "not-found-stack manifest has >= 1 source" sh -c "[ '$LEN' -ge 1 ]"

# Graph validation error: empty graph.
mkdir -p "$NANOSTACK_STORE/stacks/empty_graph2"
echo '{"name":"empty_graph2","phase_graph":[]}' > "$NANOSTACK_STORE/stacks/empty_graph2/stack.json"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack empty_graph2)
MFST=$(ls "$NANOSTACK_STORE/visual/manifests/"*empty_graph2*.manifest.json | head -1)
LEN=$(jq -r '.source_artifacts | length' "$MFST")
assert_true "graph-invalid manifest has >= 1 source" sh -c "[ '$LEN' -ge 1 ]"

# ─── Cell 23a: stack manifest records the stack definition (PR 3 pass 16) ─
printf "\n  ${DIM}Cell 23a: stack manifest records the stack def (PR 3 pass 16)${NC}\n"
PROJ="$TMP_ROOT/cell23a"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
MFST=$(ls "$NANOSTACK_STORE/visual/manifests/"*stack*compliance-release*.manifest.json | head -1)
# First source must be the stack definition file itself.
FIRST_PHASE=$(jq -r '.source_artifacts[0].phase' "$MFST")
FIRST_PATH=$(jq -r '.source_artifacts[0].path' "$MFST")
assert_true "first source phase is 'stack:compliance-release'" \
  sh -c "[ '$FIRST_PHASE' = 'stack:compliance-release' ]"
assert_true "first source path is the stack file" \
  sh -c "echo '$FIRST_PATH' | grep -q 'compliance-release/stack.json'"
# Total sources = stack def + 10 phases.
TOTAL=$(jq -r '.source_artifacts | length' "$MFST")
assert_true "manifest has 11 sources (1 stack def + 10 phases)" sh -c "[ '$TOTAL' = '11' ]"

# ─── Cell 23b: stack sorts by filename, not mtime (PR 3 pass 17) ─
printf "\n  ${DIM}Cell 23b: stack sort by filename (PR 3 pass 17)${NC}\n"
PROJ="$TMP_ROOT/cell23b"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# Save plan first.
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
sleep 1
# Save plan AGAIN to get a newer-timestamp file.
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" plan '{
  "phase":"plan",
  "summary":{"goal":"NEWER","scope":"small","planned_files":[],"plan_approval":"manual"},
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
NEWER=$(ls "$NANOSTACK_STORE/plan/"*.json | sort -r | head -1)
OLDER=$(ls "$NANOSTACK_STORE/plan/"*.json | sort | head -1)
# Touch the older file so its mtime is newer than the new one.
touch "$OLDER"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
# The stack table should reference the file with the LATER FILENAME,
# not the touched OLDER one.
assert_contains "stack picks newer-by-filename plan" "$HTML" "$NEWER"

# ─── Cell 23c: stack default records .nanostack/config.json (PR 3 pass 17) ─
printf "\n  ${DIM}Cell 23c: default-stack manifest records config.json (PR 3 pass 17)${NC}\n"
PROJ="$TMP_ROOT/cell23c"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
cat > "$NANOSTACK_STORE/config.json" <<'CFG'
{
  "schema_version": "1",
  "custom_phases": ["audit"],
  "phase_graph": [
    {"name": "think", "depends_on": []},
    {"name": "build", "depends_on": ["think"]},
    {"name": "audit", "depends_on": ["build"]},
    {"name": "ship",  "depends_on": ["audit"]}
  ]
}
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack default)
MFST=$(ls "$NANOSTACK_STORE/visual/manifests/"*stack*default*.manifest.json | head -1)
FIRST_PATH=$(jq -r '.source_artifacts[0].path' "$MFST")
assert_true "default stack manifest records config.json" \
  sh -c "echo '$FIRST_PATH' | grep -q '\.nanostack/config\.json$'"

# ─── Cell 24a: user-installed stack wins over bundled example (VA-STACK-001) ─
# Architect audit 2026-05-11 (Visual Artifacts v1 Security Audit). Without
# the fix, `bin/render-artifact.sh stack compliance-release` rendered the
# repo-bundled example even when a user-installed stack of the same name
# existed under $NANOSTACK_STORE/stacks/<name>/stack.json. The visual and
# manifest would describe the wrong workflow with no observable error,
# which breaks the trust contract for compliance/release reviews.
printf "\n  ${DIM}Cell 24a: user stack wins over bundled (VA-STACK-001)${NC}\n"
PROJ="$TMP_ROOT/cell24a-projA"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/stacks/compliance-release"
cat > "$NANOSTACK_STORE/stacks/compliance-release/stack.json" <<'CFG'
{
  "schema_version": "1",
  "name": "compliance-release",
  "display_name": "User Compliance Override",
  "description": "User-installed stack must win over the bundled example",
  "phase_graph": [
    {"name": "plan", "depends_on": []},
    {"name": "user-gate", "depends_on": ["plan"]}
  ]
}
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
assert_true "user-installed stack render produced HTML" test -f "$HTML"
assert_contains "user-installed stack display_name surfaces" "$HTML" "User Compliance Override"
assert_contains "user-installed stack has user-gate phase" "$HTML" 'data-phase="user-gate"'
assert_not_contains "user-installed stack does NOT show bundled license-audit phase" "$HTML" 'data-phase="license-audit"'
MFST=$(ls -t "$NANOSTACK_STORE/visual/manifests/"*stack*compliance-release*.manifest.json | head -1)
FIRST_PATH=$(jq -r '.source_artifacts[0].path' "$MFST")
assert_true "manifest first source is the user-installed stack file" \
  sh -c "[ '$FIRST_PATH' = '$NANOSTACK_STORE/stacks/compliance-release/stack.json' ]"
unset NANOSTACK_STORE

# ─── Cell 24b: bundled example still renders when no user stack (VA-STACK-001) ─
printf "\n  ${DIM}Cell 24b: bundled fallback (VA-STACK-001)${NC}\n"
PROJ="$TMP_ROOT/cell24b-clean"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# No $NANOSTACK_STORE/stacks/compliance-release; the bundled example
# under examples/custom-stack-template must still render.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
assert_true "bundled fallback produces HTML" test -f "$HTML"
assert_contains "bundled stack has license-audit phase" "$HTML" 'data-phase="license-audit"'
assert_contains "bundled stack display_name surfaces" "$HTML" "Compliance Release Stack"
MFST=$(ls -t "$NANOSTACK_STORE/visual/manifests/"*stack*compliance-release*.manifest.json | head -1)
FIRST_PATH=$(jq -r '.source_artifacts[0].path' "$MFST")
assert_true "bundled-fallback manifest references the example file" \
  sh -c "echo '$FIRST_PATH' | grep -q 'examples/custom-stack-template/compliance-release/stack.json'"
unset NANOSTACK_STORE

