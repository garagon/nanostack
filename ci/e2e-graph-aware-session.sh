#!/usr/bin/env bash
# e2e-graph-aware-session.sh — PR 4 of the 2026-05-10 architecture audit.
#
# Locks the graph-aware session lifecycle end-to-end:
#
#   - bin/session.sh init snapshots the active phase_graph into
#     session.json (default sprint OR project custom graph).
#   - bin/session.sh phase-complete sets next_phase and ready_phases
#     from the snapshot, not from a hardcoded sequence.
#   - bin/next-step.sh --json surfaces ready_phases plus a
#     custom-graph-aware required_before_ship list.
#   - Guided wording never exposes "phase graph" / "DAG" jargon, even
#     for custom phases.
#
# Spec acceptance, verbatim:
#   "In a graph build -> license-audit -> privacy-check ->
#    release-readiness -> ship, completing license-audit sets
#    next_phase = 'privacy-check'."
#   "Default sprint output remains unchanged."
#   "When multiple ready phases exist, next-step.sh --json returns
#    all ready phases in pending_phases or a new ready_phases field."
set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT=$(mktemp -d /tmp/nanostack-graph-session.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}expected: %s${NC}\n" "$expected"
    printf "          ${DIM}actual:   %s${NC}\n" "$actual"
  fi
}

assert_true() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}cmd: %s${NC}\n" "$*"
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}did not want to find: %s${NC}\n" "$needle"
  else
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  fi
}

new_project() {
  local name="$1"
  local proj="$TMP_ROOT/$name"
  mkdir -p "$proj/.nanostack"
  cd "$proj"
  git init -q
  git config user.email "ci@graph.test"
  git config user.name  "ci"
  export NANOSTACK_STORE="$proj/.nanostack"
}

echo "Graph-aware Session E2E"
echo "======================="
echo "Tmp root: $TMP_ROOT"
echo

SESSION_SH="$REPO/bin/session.sh"
NEXT_STEP="$REPO/bin/next-step.sh"

# Cell 1: session init snapshots the default phase_graph.
echo "[1] session init snapshots the active phase_graph"
new_project "cell1-default"
"$SESSION_SH" init development >/dev/null
nodes=$(jq -r '.phase_graph // [] | map(.name) | join(",")' "$NANOSTACK_STORE/session.json")
assert_eq "default graph nodes" "think,plan,build,review,security,qa,ship" "$nodes"
# At init, ready_phases is populated with the graph roots (every node
# with empty depends_on). For the default sprint that is just `think`.
# A previous form populated this with []; that was the regression
# Codex flagged on the PR 4 first review pass (a fresh session
# falling through to ship+can_ship=true).
ready_init=$(jq -c '.ready_phases // []' "$NANOSTACK_STORE/session.json")
assert_eq "ready_phases at init = [think] (default sprint root)" '["think"]' "$ready_init"
next_init=$(jq -r '.next_phase // "null"' "$NANOSTACK_STORE/session.json")
assert_eq "next_phase at init = think" "think" "$next_init"

# Cell 2: default sprint progression matches the legacy ordering.
# review/qa/security ARE ready in parallel after plan, but next_phase
# picks the first in graph order so existing skills continue to land
# on /review first.
echo "[2] default sprint walk preserves the historical next_phase order"
new_project "cell2-default-walk"
"$SESSION_SH" init development >/dev/null
declare -a expected_next=("plan" "review" "security" "qa" "ship" "compound")
declare -a phases_to_complete=("think" "plan" "review" "security" "qa" "ship")
for i in 0 1 2 3 4 5; do
  ph="${phases_to_complete[$i]}"
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
  np=$(jq -r '.next_phase // "null"' "$NANOSTACK_STORE/session.json")
  assert_eq "after $ph, next_phase = ${expected_next[$i]}" "${expected_next[$i]}" "$np"
done

# Cell 3: after /plan, ready_phases lists every parallel branch
# (review, qa, security) so next-step can fan out.
echo "[3] ready_phases lists every parallel branch after /plan"
new_project "cell3-fanout"
"$SESSION_SH" init development >/dev/null
for ph in think plan; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
ready=$(jq -c '.ready_phases | sort' "$NANOSTACK_STORE/session.json")
assert_eq "ready_phases after plan" '["qa","review","security"]' "$ready"

# Cell 4: spec custom graph — license-audit -> privacy-check ->
# release-readiness -> ship. Each completion advances the next ready
# phase.
echo "[4] custom compliance-release graph advances spec-correctly"
new_project "cell4-custom"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit","privacy-check","release-readiness"],
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"license-audit","depends_on":["build"]},
    {"name":"privacy-check","depends_on":["license-audit"]},
    {"name":"release-readiness","depends_on":["privacy-check"]},
    {"name":"ship","depends_on":["release-readiness"]}
  ]
}
EOF
mkdir -p "$NANOSTACK_STORE/skills/license-audit" \
         "$NANOSTACK_STORE/skills/privacy-check" \
         "$NANOSTACK_STORE/skills/release-readiness"
for skill in license-audit privacy-check release-readiness; do
  cat > "$NANOSTACK_STORE/skills/$skill/SKILL.md" <<EOF
---
name: $skill
description: custom skill
concurrency: read
---
EOF
done
"$SESSION_SH" init development >/dev/null

# Spec walk: license-audit -> privacy-check (the documented case)
declare -a custom_chain=("think" "plan" "license-audit" "privacy-check" "release-readiness" "ship")
declare -a custom_next=("plan" "license-audit" "privacy-check" "release-readiness" "ship" "compound")
for i in 0 1 2 3 4 5; do
  ph="${custom_chain[$i]}"
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
  np=$(jq -r '.next_phase // "null"' "$NANOSTACK_STORE/session.json")
  assert_eq "custom: after $ph, next_phase = ${custom_next[$i]}" "${custom_next[$i]}" "$np"
done

# Cell 5: next-step --json on a custom graph reports the custom
# required_before_ship chain, not the default review/security/qa.
echo "[5] next-step --json reports custom required_before_ship"
new_project "cell5-required"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit","privacy-check","release-readiness"],
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"license-audit","depends_on":["build"]},
    {"name":"privacy-check","depends_on":["license-audit"]},
    {"name":"release-readiness","depends_on":["privacy-check"]},
    {"name":"ship","depends_on":["release-readiness"]}
  ]
}
EOF
mkdir -p "$NANOSTACK_STORE/skills/license-audit"
cat > "$NANOSTACK_STORE/skills/license-audit/SKILL.md" <<'EOF'
---
name: license-audit
description: custom
concurrency: read
---
EOF
"$SESSION_SH" init development >/dev/null
for ph in think plan license-audit; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
out=$("$NEXT_STEP" --json 2>/dev/null)
required_sorted=$(echo "$out" | jq -c '.required_before_ship | sort')
assert_eq "required_before_ship reflects the custom graph" \
  '["license-audit","privacy-check","release-readiness"]' \
  "$required_sorted"
next=$(echo "$out" | jq -r '.next_phase')
assert_eq "next_phase = privacy-check (spec acceptance)" "privacy-check" "$next"

# Cell 6: guided wording never exposes graph jargon for custom phases.
# "I will run the <phase> step next." is acceptable; anything that
# mentions graph, DAG, dependency, topology, or upstream is not.
echo "[6] guided wording stays plain for custom phases"
new_project "cell6-guided"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit","privacy-check","release-readiness"],
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"license-audit","depends_on":["build"]},
    {"name":"privacy-check","depends_on":["license-audit"]},
    {"name":"release-readiness","depends_on":["privacy-check"]},
    {"name":"ship","depends_on":["release-readiness"]}
  ]
}
EOF
mkdir -p "$NANOSTACK_STORE/skills/license-audit"
cat > "$NANOSTACK_STORE/skills/license-audit/SKILL.md" <<'EOF'
---
name: license-audit
description: custom
concurrency: read
---
EOF
"$SESSION_SH" init development --profile guided >/dev/null
for ph in think plan license-audit; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
msg=$("$NEXT_STEP" --json 2>/dev/null | jq -r '.user_message')
for jargon in "phase_graph" "phase graph" "DAG" "dependency" "topology" "upstream"; do
  assert_not_contains "guided user_message has no \"$jargon\"" "$jargon" "$msg"
done
assert_true "guided user_message names the custom phase" \
  bash -c "echo '$msg' | grep -qiF 'privacy-check'"

# Cell 8: a freshly-initialized custom session must report the root
# of the graph as next_phase, NOT collapse to "ship". Codex caught
# this on the PR 4 first review pass: a session with next_phase=null
# and ready_phases=[] used to fall back to ship+can_ship=true even
# though the required custom phases were still incomplete.
echo "[8] fresh custom session reports the graph root, not ship"
new_project "cell8-fresh"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"license-audit","depends_on":["build"]},
    {"name":"ship","depends_on":["license-audit"]}
  ]
}
EOF
mkdir -p "$NANOSTACK_STORE/skills/license-audit"
cat > "$NANOSTACK_STORE/skills/license-audit/SKILL.md" <<'EOF'
---
name: license-audit
description: custom
concurrency: read
---
EOF
"$SESSION_SH" init development >/dev/null
out=$("$NEXT_STEP" --json 2>/dev/null)
assert_eq "fresh session next_phase = think (graph root)" "think" \
  "$(echo "$out" | jq -r '.next_phase')"
assert_eq "fresh session can_ship = false" "false" \
  "$(echo "$out" | jq -r '.can_ship')"
assert_eq "ready_phases at init = [think]" '["think"]' \
  "$(echo "$out" | jq -c '.ready_phases')"

# Cell 9: a custom graph that keeps the default phase names but
# rewires the dependencies (review -> qa -> security serialized)
# must use the graph-aware path. Codex caught the name-only detection
# regression on the PR 4 first review pass: the previous "compare by
# names" check treated the rewired graph as the default sprint and
# the legacy peer logic could suggest security before qa.
echo "[9] same-name-different-deps graph routes through graph-aware"
new_project "cell9-rewired"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"review","depends_on":["build"]},
    {"name":"qa","depends_on":["review"]},
    {"name":"security","depends_on":["qa"]},
    {"name":"ship","depends_on":["security"]}
  ]
}
EOF
"$SESSION_SH" init development >/dev/null
for ph in think plan review; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
out=$("$NEXT_STEP" --json 2>/dev/null)
assert_eq "rewired graph: after review, next_phase = qa (not security)" \
  "qa" "$(echo "$out" | jq -r '.next_phase')"
assert_eq "rewired graph: ready_phases = [qa]" \
  '["qa"]' "$(echo "$out" | jq -c '.ready_phases')"
assert_eq "rewired graph: can_ship still false" \
  "false" "$(echo "$out" | jq -r '.can_ship')"

# Cell 9b: a graph that keeps the default node names AND dependencies
# but declares them in a different ORDER (e.g. security before review)
# is a legitimate custom graph. Codex caught this on the PR 4 second
# review pass: sorting the outer node array during comparison made
# next-step.sh suggest /review while session.json had next_phase=
# security, breaking the single-source-of-truth contract.
echo "[9b] reordered default graph routes through graph-aware"
new_project "cell9b-reorder"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"security","depends_on":["build"]},
    {"name":"review","depends_on":["build"]},
    {"name":"qa","depends_on":["build"]},
    {"name":"ship","depends_on":["review","qa","security"]}
  ]
}
EOF
"$SESSION_SH" init development >/dev/null
for ph in think plan; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
out=$("$NEXT_STEP" --json 2>/dev/null)
# Reordered graph put security first; session.sh's graph-aware logic
# picks the first declared ready phase. next-step.sh must agree.
assert_eq "reordered graph: next_phase = security (declared first)" \
  "security" "$(echo "$out" | jq -r '.next_phase')"
session_next=$(jq -r '.next_phase' "$NANOSTACK_STORE/session.json")
assert_eq "next-step agrees with session.json next_phase" \
  "$session_next" "$(echo "$out" | jq -r '.next_phase')"

# Cell 9c: starting one of several ready phases drops it from
# ready_phases so downstream schedulers do not start it twice. Codex
# flagged the stale cache on the PR 4 third review pass: in a graph
# where plan unblocks audit-a and audit-b in parallel, starting
# audit-a used to leave session.json saying both were ready.
echo "[9c] phase-start removes the active phase from ready_phases"
new_project "cell9c-parallel"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["audit-a","audit-b"],
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"audit-a","depends_on":["build"]},
    {"name":"audit-b","depends_on":["build"]},
    {"name":"ship","depends_on":["audit-a","audit-b"]}
  ]
}
EOF
mkdir -p "$NANOSTACK_STORE/skills/audit-a" "$NANOSTACK_STORE/skills/audit-b"
for skill in audit-a audit-b; do
  cat > "$NANOSTACK_STORE/skills/$skill/SKILL.md" <<EOF
---
name: $skill
description: custom
concurrency: read
---
EOF
done
"$SESSION_SH" init development >/dev/null
for ph in think plan; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
ready_before=$(jq -c '.ready_phases | sort' "$NANOSTACK_STORE/session.json")
assert_eq "after plan: both audits are ready" '["audit-a","audit-b"]' "$ready_before"

"$SESSION_SH" phase-start audit-a >/dev/null
ready_after=$(jq -c '.ready_phases' "$NANOSTACK_STORE/session.json")
next_after=$(jq -r '.next_phase' "$NANOSTACK_STORE/session.json")
assert_eq "after starting audit-a: ready drops audit-a" '["audit-b"]' "$ready_after"
assert_eq "after starting audit-a: next_phase points at audit-b" "audit-b" "$next_after"

# Cell 9d: a legacy session (no phase_graph snapshot, from a pre-PR-4
# build) must fall back to the artifact-based legacy lookup so an
# in-progress sprint upgraded mid-flight still advances. Codex flagged
# the upgrade regression on the PR 4 fifth review pass.
echo "[9d] legacy session without phase_graph uses artifact fallback"
new_project "cell9d-legacy"
cat > "$NANOSTACK_STORE/session.json" <<'EOF'
{
  "schema_version": "2",
  "profile": "professional",
  "phase_log": [
    {"phase":"think","status":"completed"},
    {"phase":"plan","status":"completed"},
    {"phase":"review","status":"completed"}
  ]
}
EOF
out=$("$NEXT_STEP" --json 2>/dev/null)
assert_eq "legacy session: next_phase = security (artifact fallback)" \
  "security" "$(echo "$out" | jq -r '.next_phase')"
assert_eq "legacy session: ready_phases includes qa" \
  "true" "$(echo "$out" | jq '.ready_phases | any(. == "qa")')"
assert_eq "legacy session: can_ship still false" \
  "false" "$(echo "$out" | jq -r '.can_ship')"

# Cell 9e: can_ship is derived from graph dependencies, not from
# whether NEXT_PHASE happens to be "ship". For the default sprint
# after review+qa+security complete, ship is ready and can_ship is
# true regardless of which phase appears as next_phase. Codex flagged
# the next_phase-vs-required_before_ship mismatch on the PR 4 fifth
# review pass.
echo "[9e] can_ship reflects required_before_ship, not next_phase identity"
new_project "cell9e-canship"
"$SESSION_SH" init development >/dev/null
for ph in think plan review qa security; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
out=$("$NEXT_STEP" --json 2>/dev/null)
assert_eq "after r+q+s: ship is next_phase" "ship" "$(echo "$out" | jq -r '.next_phase')"
assert_eq "after r+q+s: can_ship = true (deps met)" "true" "$(echo "$out" | jq -r '.can_ship')"
assert_eq "after r+q+s: ready_phases = [ship]" \
  '["ship"]' "$(echo "$out" | jq -c '.ready_phases')"

# Cell 9f: build is the conductor's no-artifact stage and is auto-
# promoted to "satisfied" once its declared deps land, but only when
# it is not currently in_progress. Codex caught the racy promotion
# on the PR 4 sixth review pass: a caller that did session.sh
# phase-start build still unblocked review/qa/security right away.
echo "[9f] in-progress build does not unblock downstream phases"
new_project "cell9f-build-running"
"$SESSION_SH" init development >/dev/null
for ph in think plan; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
"$SESSION_SH" phase-start build >/dev/null
ready_during_build=$(jq -c '.ready_phases' "$NANOSTACK_STORE/session.json")
assert_eq "build in_progress: ready_phases is empty" '[]' "$ready_during_build"
# Once build is conceptually done (the user finishes the dev work and
# the next phase-start lands), review/qa/security come back online.
# We simulate the dev finishing build by completing it explicitly.
"$SESSION_SH" phase-complete build >/dev/null
ready_after_build=$(jq -c '.ready_phases | sort' "$NANOSTACK_STORE/session.json")
assert_eq "build completed: post-build phases ready" \
  '["qa","review","security"]' "$ready_after_build"
# Cell 9g: a custom graph where ship has no post-build gates (only
# depends on build/plan/think) must NOT report can_ship=true on a
# fresh session. The previous form computed can_ship from "required
# set minus completed" — empty required set collapsed to true even
# before think/plan ran. Codex caught the premature-ship hazard on
# the PR 4 eighth review pass.
echo "[9g] ship-on-build-only graph gates can_ship on ship readiness"
new_project "cell9g-no-gates"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"ship","depends_on":["build"]}
  ]
}
EOF
"$SESSION_SH" init development >/dev/null
out=$("$NEXT_STEP" --json 2>/dev/null)
assert_eq "fresh ship-on-build graph: can_ship = false" "false" \
  "$(echo "$out" | jq -r '.can_ship')"
assert_eq "fresh ship-on-build graph: next_phase = think" "think" \
  "$(echo "$out" | jq -r '.next_phase')"
# After think + plan, build auto-promotes and ship becomes ready
for ph in think plan; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
out=$("$NEXT_STEP" --json 2>/dev/null)
assert_eq "after plan: can_ship = true (ship is ready)" "true" \
  "$(echo "$out" | jq -r '.can_ship')"
assert_eq "after plan: next_phase = ship" "ship" \
  "$(echo "$out" | jq -r '.next_phase')"

# Cell 9h: conductor sprint started with --phases (no config.phase_graph)
# must update the session snapshot so next-step.sh sees the custom
# graph. Before PR 4 pass 9 this entry point left the session pointing
# at the default graph and next-step.sh suggested /review even though
# the conductor had a license-audit chain. Codex caught the missed
# conductor entry point on the ninth review pass.
echo "[9h] conductor --phases updates the session phase_graph snapshot"
new_project "cell9h-conductor"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"]}
EOF
mkdir -p "$NANOSTACK_STORE/skills/license-audit"
cat > "$NANOSTACK_STORE/skills/license-audit/SKILL.md" <<'EOF'
---
name: license-audit
description: custom
concurrency: read
---
EOF
"$SESSION_SH" init development >/dev/null
nodes_before=$(jq -c '.phase_graph | map(.name)' "$NANOSTACK_STORE/session.json")
assert_eq "before conductor: session phase_graph is the default sprint" \
  '["think","plan","build","review","security","qa","ship"]' "$nodes_before"

"$REPO/conductor/bin/sprint.sh" start --phases \
  '[{"name":"think","depends_on":[]},{"name":"plan","depends_on":["think"]},{"name":"build","depends_on":["plan"]},{"name":"license-audit","depends_on":["build"]},{"name":"ship","depends_on":["license-audit"]}]' \
  >/dev/null

nodes_after=$(jq -c '.phase_graph | map(.name)' "$NANOSTACK_STORE/session.json")
assert_eq "after conductor: session phase_graph is the conductor graph" \
  '["think","plan","build","license-audit","ship"]' "$nodes_after"
# Walk to confirm license-audit shows up as next_phase at the right time
for ph in think plan; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
next_after_plan=$(jq -r '.next_phase' "$NANOSTACK_STORE/session.json")
assert_eq "after plan in a conductor sprint: next_phase = license-audit" \
  "license-audit" "$next_after_plan"

# Cell 9i: /feature sessions skip /think by contract. The graph-aware
# lifecycle must NOT advertise think as ready after /plan completes;
# session.sh init must pre-seed think as completed so the dep graph
# treats it as satisfied. Codex caught the regression on the PR 4
# eleventh review pass.
echo "[9i] /feature session pre-seeds think as completed"
new_project "cell9i-feature"
"$SESSION_SH" init feature --autopilot --plan-approval auto >/dev/null
think_status=$(jq -r '.phase_log[] | select(.phase == "think") | .status' "$NANOSTACK_STORE/session.json")
assert_eq "/feature init seeds think as completed" "completed" "$think_status"
assert_eq "/feature init next_phase = plan (not think)" "plan" \
  "$(jq -r '.next_phase' "$NANOSTACK_STORE/session.json")"
# Walk plan + review and confirm next_phase never falls back to think
for ph in plan review; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
next_after_review=$(jq -r '.next_phase' "$NANOSTACK_STORE/session.json")
assert_eq "/feature after review: next_phase != think" "security" "$next_after_review"

# Cell 9j: the guard's phase-gate reads required phases from the
# session's phase_graph too. A custom workflow stack whose ship
# depends on license-audit must gate git commit on license-audit
# being completed, not on the hardcoded review/security/qa trio.
# Codex caught the gate-vs-can_ship drift on the PR 4 eleventh
# review pass.
echo "[9j] phase-gate gates on the graph's ship ancestors"
new_project "cell9j-gate"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"license-audit","depends_on":["build"]},
    {"name":"ship","depends_on":["license-audit"]}
  ]
}
EOF
mkdir -p "$NANOSTACK_STORE/skills/license-audit"
cat > "$NANOSTACK_STORE/skills/license-audit/SKILL.md" <<'EOF'
---
name: license-audit
description: custom
concurrency: read
---
EOF
"$SESSION_SH" init development >/dev/null
# Walk think + plan first so the gate is in "active sprint" mode.
# The gate skips when no phases have started (a freshly-initialized
# session is not yet a sprint to enforce).
for ph in think plan; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
# Touch a tracked file so last_code_timestamp gives the gate something
# fresher than any artifact (otherwise the missing-phase check is
# bypassed because nothing changed since the last commit).
echo "scratch" > scratch.txt
git add scratch.txt && git commit -q -m "scratch" >/dev/null 2>&1 || true
echo "more" >> scratch.txt
# Before license-audit completes, phase-gate must block git commit.
set +e
"$REPO/guard/bin/phase-gate.sh" "git commit -m wip" >/dev/null 2>&1
rc=$?
set -e
assert_eq "phase-gate blocks git commit before license-audit (rc 1)" "1" "$rc"
# Complete license-audit via real save-artifact so the gate finds
# a fresh artifact for the only graph-required ancestor of ship.
"$SESSION_SH" phase-start license-audit >/dev/null
"$REPO/bin/save-artifact.sh" license-audit \
  '{"phase":"license-audit","summary":{"status":"OK"},"context_checkpoint":{"summary":"clean"}}' >/dev/null
set +e
"$REPO/guard/bin/phase-gate.sh" "git commit -m ship" >/dev/null 2>&1
rc=$?
set -e
assert_eq "phase-gate allows git commit after license-audit (rc 0)" "0" "$rc"

# Cell 9k: a graph with no post-build gates (think -> plan -> build
# -> ship) must let phase-gate allow the commit. Codex caught the
# symmetric collapse on the PR 4 twelfth review pass: an empty
# graph-derived REQUIRED_PHASES used to fall back to the built-in
# trio, blocking valid no-gate workflows.
echo "[9k] phase-gate honors an empty post-build gate set"
new_project "cell9k-nogate"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"ship","depends_on":["build"]}
  ]
}
EOF
"$SESSION_SH" init development >/dev/null
for ph in think plan; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
echo "scratch" > scratch.txt
git add scratch.txt && git commit -q -m "scratch" >/dev/null 2>&1 || true
echo "more" >> scratch.txt
set +e
"$REPO/guard/bin/phase-gate.sh" "git commit -m wip" >/dev/null 2>&1
rc=$?
set -e
assert_eq "no-gate graph: phase-gate allows commit (rc 0)" "0" "$rc"

# Cell 10: default sprint user_message remains exactly the historical
# wording. No regression for built-in flows.
echo "[10] default sprint user_message is unchanged"
new_project "cell7-default-msg"
"$SESSION_SH" init development >/dev/null
for ph in think plan; do
  "$SESSION_SH" phase-start "$ph" >/dev/null
  "$SESSION_SH" phase-complete "$ph" >/dev/null
done
msg=$("$NEXT_STEP" --json 2>/dev/null | jq -r '.user_message')
assert_eq "professional after plan = review wording" \
  "Run /review to check scope, structure, and edge cases." \
  "$msg"

cd "$TMP_ROOT"

echo
echo "======================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Graph-aware Session E2E: %d checks passed, 0 failed${NC}\n" "$PASS"
  exit 0
else
  printf "${RED}Graph-aware Session E2E: %d failed of %d total${NC}\n" "$FAIL" "$TOTAL"
  exit 1
fi
