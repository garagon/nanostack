#!/usr/bin/env bash
# e2e-custom-routing.sh — Custom routing contract (PR 5 of architecture vNext).
#
# Locks the phase_context contract end-to-end:
#
#   - A custom phase with no phase_context block keeps the existing
#     dependency-only behavior (routing.declared = false).
#   - phase_context.trust = strict drops integrity_missing artifacts
#     so a custom skill that asked for strict evidence never sees a
#     path it cannot verify.
#   - phase_context.upstream_required / upstream_optional surface in
#     routing so consumers can read declared intent.
#   - phase_context.max_age_days overrides the per-phase default.
#   - phase_context.solutions.tags loads matching solutions filtered
#     by content match, limited to solutions.limit.
#   - phase_context.diarizations.paths / keywords loads matching
#     diarizations without depending on git diff.
#
# Spec acceptance, verbatim:
#   "A custom skill can ask for strict upstream artifacts without
#    local helper code."
#   "A custom skill can request solution search tags."
#   "A custom skill can request diarizations by path or keyword."
#   "Missing required upstreams are explicit in upstream_status, not
#    silently null."
#   "Backward compatibility: custom skills with no context: block
#    keep current behavior."
set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT=$(mktemp -d /tmp/nanostack-custom-routing.XXXXXX)
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

new_project() {
  local name="$1"
  local proj="$TMP_ROOT/$name"
  mkdir -p "$proj/.nanostack/skills/license-audit" \
           "$proj/.nanostack/know-how/solutions" \
           "$proj/.nanostack/know-how/diarizations" \
           "$proj/.nanostack/review"
  cd "$proj"
  git init -q
  git config user.email "ci@routing.test"
  git config user.name  "ci"
  export NANOSTACK_STORE="$proj/.nanostack"
  cat > "$proj/.nanostack/skills/license-audit/SKILL.md" <<'EOF'
---
name: license-audit
description: custom skill for routing tests
concurrency: read
depends_on: [review]
---
EOF
}

# Save a "verified" review artifact via the real save-artifact path.
save_verified_review() {
  "$REPO/bin/save-artifact.sh" review \
    '{"phase":"review","summary":{"v":1,"blocking":0},"scope_drift":{"status":"clean"},"findings":[],"context_checkpoint":{"summary":"routing test"}}' >/dev/null
}

# Save a review artifact WITHOUT .integrity (legacy / stripped).
save_integrity_missing_review() {
  local ts="$(date -u +%Y%m%dT%H%M%S)"
  printf '%s\n' '{"phase":"review","project":"'"$(pwd)"'","summary":"missing integrity"}' > "$NANOSTACK_STORE/review/${ts}.json"
}

echo "Custom Routing Contract E2E"
echo "==========================="
echo "Tmp root: $TMP_ROOT"
echo

# Cell 1: backward compat — no phase_context keeps the existing
# dependency-only behavior. routing.declared = false.
echo "[1] backward compat: no phase_context keeps current behavior"
new_project "cell1-backcompat"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases": ["license-audit"]}
EOF
out=$("$REPO/bin/resolve.sh" license-audit 2>/dev/null)
assert_eq "routing.declared = false" "false" "$(echo "$out" | jq -r '.routing.declared')"
assert_eq "routing.trust = normal (default)" "normal" "$(echo "$out" | jq -r '.routing.trust')"
assert_eq "solutions empty (no tags)" "0" "$(echo "$out" | jq '.solutions | length')"
assert_eq "diarizations empty (no paths)" "0" "$(echo "$out" | jq '.diarizations | length')"

# Cell 2: missing required upstream surfaces explicitly. Spec says
# upstream_status reports the state, not silently null.
echo "[2] missing required upstream is explicit in upstream_status"
new_project "cell2-missing"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_context": {
    "license-audit": {
      "upstream_required": ["review"]
    }
  }
}
EOF
out=$("$REPO/bin/resolve.sh" license-audit 2>/dev/null)
assert_eq "upstream_status.review = missing" "missing" \
  "$(echo "$out" | jq -r '.upstream_status.review')"
assert_eq "routing.upstream_required lists review" '["review"]' \
  "$(echo "$out" | jq -c '.routing.upstream_required')"

# Cell 3: strict trust drops integrity_missing artifacts.
echo "[3] strict trust drops integrity_missing artifacts"
new_project "cell3-strict"
save_integrity_missing_review
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_context": {
    "license-audit": { "trust": "strict" }
  }
}
EOF
out=$("$REPO/bin/resolve.sh" license-audit 2>/dev/null)
assert_eq "strict: upstream_status.review = integrity_missing (diagnostic preserved)" \
  "integrity_missing" "$(echo "$out" | jq -r '.upstream_status.review')"
assert_eq "strict: upstream_artifacts.review = null (artifact dropped)" \
  "null" "$(echo "$out" | jq -r '.upstream_artifacts.review')"

# Cell 4: normal trust keeps the integrity_missing artifact in
# upstream_artifacts so legacy stores continue to load.
echo "[4] normal trust keeps integrity_missing artifact (legacy compat)"
new_project "cell4-normal"
save_integrity_missing_review
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_context": {
    "license-audit": { "trust": "normal" }
  }
}
EOF
out=$("$REPO/bin/resolve.sh" license-audit 2>/dev/null)
assert_eq "normal: upstream_status.review = integrity_missing" \
  "integrity_missing" "$(echo "$out" | jq -r '.upstream_status.review')"
# upstream_artifacts.review should be a string path (not null), since
# legacy artifacts still load under normal trust.
art=$(echo "$out" | jq -r '.upstream_artifacts.review // ""')
assert_eq "normal: upstream_artifacts.review is the stored path" \
  "true" "$( [ -n "$art" ] && echo "true" || echo "false" )"

# Cell 5: max_age_days overrides the default per-phase age. We mark
# an artifact 90 days old; the default is 30, so max_age_days = 120
# is required to load it.
echo "[5] max_age_days overrides the per-phase age"
new_project "cell5-age"
save_verified_review
art_path=$(ls "$NANOSTACK_STORE/review/"*.json | head -1)
# Touch the artifact's mtime 90 days into the past.
touch -t "$(date -u -v-90d +%Y%m%d%H%M.%S 2>/dev/null || date -u --date='90 days ago' +%Y%m%d%H%M.%S)" "$art_path" 2>/dev/null || true
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_context": {
    "license-audit": { "max_age_days": 120 }
  }
}
EOF
out=$("$REPO/bin/resolve.sh" license-audit 2>/dev/null)
assert_eq "max_age_days = 120 loads a 90-day-old verified artifact" \
  "verified" "$(echo "$out" | jq -r '.upstream_status.review')"
assert_eq "routing.max_age_days = 120 reported" "120" \
  "$(echo "$out" | jq -r '.routing.max_age_days')"

# Cell 6: solution_tags loads matching solutions filtered by content.
echo "[6] solution_tags filters know-how/solutions"
new_project "cell6-solutions"
cat > "$NANOSTACK_STORE/know-how/solutions/license-resolution.md" <<'EOF'
---
tags: [license, oss]
---
license stuff
EOF
cat > "$NANOSTACK_STORE/know-how/solutions/random.md" <<'EOF'
---
tags: [debug]
---
unrelated content
EOF
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_context": {
    "license-audit": {
      "solutions": { "tags": ["license"], "limit": 5 }
    }
  }
}
EOF
out=$("$REPO/bin/resolve.sh" license-audit 2>/dev/null)
sol_count=$(echo "$out" | jq '.solutions | length')
sol_first=$(echo "$out" | jq -r '.solutions[0] // ""')
assert_eq "solutions filtered to license-tagged file" "1" "$sol_count"
case "$sol_first" in
  *license-resolution.md) PASS=$((PASS+1)); printf "    ${GREEN}OK${NC}    %s\n" "selected solution is license-resolution.md" ;;
  *) FAIL=$((FAIL+1)); printf "    ${RED}FAIL${NC}  %s (got %s)\n" "selected solution is license-resolution.md" "$sol_first" ;;
esac

# Cell 7: diarization paths / keywords. A diarization whose subject
# matches one of the declared paths is loaded.
echo "[7] diarization paths load matching subjects"
new_project "cell7-diarizations"
cat > "$NANOSTACK_STORE/know-how/diarizations/2026-04-01-pkg.md" <<'EOF'
---
subject: package.json
date: 2026-04-01
---
notes about package.json
EOF
cat > "$NANOSTACK_STORE/know-how/diarizations/2026-04-01-other.md" <<'EOF'
---
subject: src/unrelated
date: 2026-04-01
---
unrelated notes
EOF
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_context": {
    "license-audit": {
      "diarizations": { "paths": ["package.json"], "keywords": [] }
    }
  }
}
EOF
out=$("$REPO/bin/resolve.sh" license-audit 2>/dev/null)
diar_count=$(echo "$out" | jq '.diarizations | length')
diar_subj=$(echo "$out" | jq -r '.diarizations[0].subject // ""')
assert_eq "diarizations filtered to package.json subject" "1" "$diar_count"
assert_eq "diarization subject = package.json" "package.json" "$diar_subj"

# Cell 7a: a routed upstream that is NOT in depends_on still gets
# its artifact looked up. The routing contract is supposed to give
# skills a way to ask for context outside the dependency edges;
# Codex caught the missing wiring on the PR 5 first review pass
# (declaring upstream_optional: ["security"] without depends_on
# left security absent from upstream_status entirely).
echo "[7a] routed upstreams not in depends_on are still resolved"
new_project "cell7a-routed-only"
"$REPO/bin/save-artifact.sh" security \
  '{"phase":"security","summary":{"v":1},"findings":[],"context_checkpoint":{"summary":"routing test"}}' >/dev/null
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_context": {
    "license-audit": {
      "upstream_optional": ["security"]
    }
  }
}
EOF
out=$("$REPO/bin/resolve.sh" license-audit 2>/dev/null)
assert_eq "upstream_status.security present even though only routed" \
  "verified" "$(echo "$out" | jq -r '.upstream_status.security')"
sec_art=$(echo "$out" | jq -r '.upstream_artifacts.security // ""')
assert_eq "upstream_artifacts.security is the resolved path" \
  "true" "$( [ -n "$sec_art" ] && echo "true" || echo "false" )"

# Cell 8: routing block surfaces every applied field so consumers
# can audit what the resolver did.
echo "[8] routing block surfaces every applied field"
new_project "cell8-routing-shape"
cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_context": {
    "license-audit": {
      "trust": "strict",
      "upstream_required": ["review"],
      "upstream_optional": ["security"],
      "max_age_days": 7,
      "solutions": { "tags": ["compliance"], "limit": 3 },
      "diarizations": { "paths": ["src/privacy"], "keywords": ["pii"] }
    }
  }
}
EOF
out=$("$REPO/bin/resolve.sh" license-audit 2>/dev/null)
assert_eq "routing.declared = true" "true" "$(echo "$out" | jq -r '.routing.declared')"
assert_eq "routing.trust = strict" "strict" "$(echo "$out" | jq -r '.routing.trust')"
assert_eq "routing.upstream_required" '["review"]' "$(echo "$out" | jq -c '.routing.upstream_required')"
assert_eq "routing.upstream_optional" '["security"]' "$(echo "$out" | jq -c '.routing.upstream_optional')"
assert_eq "routing.max_age_days" "7" "$(echo "$out" | jq -r '.routing.max_age_days')"
assert_eq "routing.solutions.tags" '["compliance"]' "$(echo "$out" | jq -c '.routing.solutions.tags')"
assert_eq "routing.solutions.limit" "3" "$(echo "$out" | jq -r '.routing.solutions.limit')"
assert_eq "routing.diarizations.paths" '["src/privacy"]' "$(echo "$out" | jq -c '.routing.diarizations.paths')"
assert_eq "routing.diarizations.keywords" '["pii"]' "$(echo "$out" | jq -c '.routing.diarizations.keywords')"

cd "$TMP_ROOT"

echo
echo "==========================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Custom Routing E2E: %d checks passed, 0 failed${NC}\n" "$PASS"
  exit 0
else
  printf "${RED}Custom Routing E2E: %d failed of %d total${NC}\n" "$FAIL" "$TOTAL"
  exit 1
fi
