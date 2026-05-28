#!/usr/bin/env bash
# e2e-custom-routing.sh — Custom routing contract (PR 5 of architecture vNext).
#
# Locks the phase_context contract end-to-end:
#
#   - A custom phase with no phase_context block keeps the existing
#     dependency-only behavior (routing.declared = false).
#   - phase_context.trust = strict drops integrity_missing artifacts.
#   - phase_context.upstream_required / upstream_optional surface in routing.
#   - phase_context.max_age_days overrides the per-phase default.
#   - phase_context.solutions.tags loads matching solutions (literal match).
#   - phase_context.diarizations.paths / keywords loads matching diarizations.
#
# Migrated onto ci/lib/harness.sh + ci/lib/fixtures.sh (Harness vNext
# PR 2). Same cells, same check count (35). Supports --filter <pattern>.
set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/ci/lib/harness.sh"
. "$REPO/ci/lib/fixtures.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --filter) nh_set_filter "${2:-}"; shift 2 ;;
    --filter=*) nh_set_filter "${1#*=}"; shift ;;
    *) shift ;;
  esac
done

nh_init custom-routing nanostack-custom-routing
nh_require_cmd git jq

RESOLVE="$REPO/bin/resolve.sh"

# A routing project: git repo + exported store + the license-audit custom
# skill (depends_on review) + know-how dirs. Uses the shared git/store
# fixtures; the skill frontmatter and know-how layout are suite-specific.
routing_project() {
  local name="$1" proj
  proj=$(nf_new_git_project "$name")
  # Call nf_export_store directly (not in $()) so the NANOSTACK_STORE export
  # lands in this shell, not a command-substitution subshell.
  nf_export_store "$proj" >/dev/null
  cd "$proj"
  mkdir -p "$NANOSTACK_STORE/skills/license-audit" "$NANOSTACK_STORE/know-how/solutions" \
           "$NANOSTACK_STORE/know-how/diarizations" "$NANOSTACK_STORE/review"
  cat > "$NANOSTACK_STORE/skills/license-audit/SKILL.md" <<'EOF'
---
name: license-audit
description: custom skill for routing tests
concurrency: read
depends_on: [review]
---
EOF
  printf '%s' "$proj"
}

save_verified_review() {
  nf_save_artifact review \
    '{"phase":"review","summary":{"v":1,"blocking":0},"scope_drift":{"status":"clean"},"findings":[],"context_checkpoint":{"summary":"routing test"}}' >/dev/null
}

# A review artifact with no .integrity, via the shared fixture.
save_integrity_missing_review() {
  nf_write_artifact "$NANOSTACK_STORE" review integrity_missing "$(date -u +%Y%m%dT%H%M%S)" "$(pwd)" >/dev/null
}

# Cell 1: backward compat — no phase_context keeps dependency-only behavior.
cell_backcompat() {
  routing_project "cell1-backcompat" >/dev/null
  printf '%s\n' '{"custom_phases": ["license-audit"]}' > "$NANOSTACK_STORE/config.json"
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "routing.declared = false"        "false"  "$(echo "$out" | jq -r '.routing.declared')"
  nh_assert_eq "routing.trust = normal (default)" "normal" "$(echo "$out" | jq -r '.routing.trust')"
  nh_assert_eq "solutions empty (no tags)"        "0"      "$(echo "$out" | jq '.solutions | length')"
  nh_assert_eq "diarizations empty (no paths)"    "0"      "$(echo "$out" | jq '.diarizations | length')"
}

# Cell 2: missing required upstream surfaces explicitly.
cell_missing_required() {
  routing_project "cell2-missing" >/dev/null
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"upstream_required":["review"]}}}
EOF
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "upstream_status.review = missing" "missing" "$(echo "$out" | jq -r '.upstream_status.review')"
  nh_assert_eq "routing.upstream_required lists review" '["review"]' "$(echo "$out" | jq -c '.routing.upstream_required')"
}

# Cell 3: strict trust drops integrity_missing artifacts.
cell_strict_drops() {
  routing_project "cell3-strict" >/dev/null
  save_integrity_missing_review
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"trust":"strict"}}}
EOF
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "strict: upstream_status.review = integrity_missing (diagnostic preserved)" \
    "integrity_missing" "$(echo "$out" | jq -r '.upstream_status.review')"
  nh_assert_eq "strict: upstream_artifacts.review = null (artifact dropped)" \
    "null" "$(echo "$out" | jq -r '.upstream_artifacts.review')"
}

# Cell 4: normal trust keeps the integrity_missing artifact.
cell_normal_keeps() {
  routing_project "cell4-normal" >/dev/null
  save_integrity_missing_review
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"trust":"normal"}}}
EOF
  local out art; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "normal: upstream_status.review = integrity_missing" \
    "integrity_missing" "$(echo "$out" | jq -r '.upstream_status.review')"
  art=$(echo "$out" | jq -r '.upstream_artifacts.review // ""')
  nh_assert_eq "normal: upstream_artifacts.review is the stored path" \
    "true" "$( [ -n "$art" ] && echo "true" || echo "false" )"
}

# Cell 5: max_age_days overrides the default per-phase age.
cell_max_age() {
  routing_project "cell5-age" >/dev/null
  save_verified_review
  local art_path; art_path=$(ls "$NANOSTACK_STORE/review/"*.json | head -1)
  touch -t "$(date -u -v-90d +%Y%m%d%H%M.%S 2>/dev/null || date -u --date='90 days ago' +%Y%m%d%H%M.%S)" "$art_path" 2>/dev/null || true
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"max_age_days":120}}}
EOF
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "max_age_days = 120 loads a 90-day-old verified artifact" \
    "verified" "$(echo "$out" | jq -r '.upstream_status.review')"
  nh_assert_eq "routing.max_age_days = 120 reported" "120" "$(echo "$out" | jq -r '.routing.max_age_days')"
}

# Cell 6: solution_tags filters know-how/solutions.
cell_solution_tags() {
  routing_project "cell6-solutions" >/dev/null
  printf '%s\n' '---' 'tags: [license, oss]' '---' 'license stuff' > "$NANOSTACK_STORE/know-how/solutions/license-resolution.md"
  printf '%s\n' '---' 'tags: [debug]' '---' 'unrelated content' > "$NANOSTACK_STORE/know-how/solutions/random.md"
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"solutions":{"tags":["license"],"limit":5}}}}
EOF
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "solutions filtered to license-tagged file" "1" "$(echo "$out" | jq '.solutions | length')"
  nh_assert_contains "selected solution is license-resolution.md" "$(echo "$out" | jq -r '.solutions[0] // ""')" "license-resolution.md"
}

# Cell 7: diarization paths load matching subjects.
cell_diarization_paths() {
  routing_project "cell7-diarizations" >/dev/null
  printf '%s\n' '---' 'subject: package.json' 'date: 2026-04-01' '---' 'notes' > "$NANOSTACK_STORE/know-how/diarizations/2026-04-01-pkg.md"
  printf '%s\n' '---' 'subject: src/unrelated' 'date: 2026-04-01' '---' 'unrelated' > "$NANOSTACK_STORE/know-how/diarizations/2026-04-01-other.md"
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"diarizations":{"paths":["package.json"],"keywords":[]}}}}
EOF
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "diarizations filtered to package.json subject" "1" "$(echo "$out" | jq '.diarizations | length')"
  nh_assert_eq "diarization subject = package.json" "package.json" "$(echo "$out" | jq -r '.diarizations[0].subject // ""')"
}

# Cell 7a: routed upstreams not in depends_on are still resolved.
cell_routed_only() {
  routing_project "cell7a-routed-only" >/dev/null
  nf_save_artifact security '{"phase":"security","summary":{"v":1},"findings":[],"context_checkpoint":{"summary":"routing test"}}' >/dev/null
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"upstream_optional":["security"]}}}
EOF
  local out sec_art; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "upstream_status.security present even though only routed" \
    "verified" "$(echo "$out" | jq -r '.upstream_status.security')"
  sec_art=$(echo "$out" | jq -r '.upstream_artifacts.security // ""')
  nh_assert_eq "upstream_artifacts.security is the resolved path" \
    "true" "$( [ -n "$sec_art" ] && echo "true" || echo "false" )"
}

# Cell 7b: phase_context in the global ~/.nanostack/config.json is honored.
cell_global_config() {
  local gh gp
  gh="$NH_TMP/global-home"; gp="$NH_TMP/global-proj"
  mkdir -p "$gh/.nanostack" "$gp/.nanostack/skills/license-audit"
  cat > "$gh/.nanostack/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"trust":"strict","upstream_required":["review"]}}}
EOF
  cat > "$gp/.nanostack/skills/license-audit/SKILL.md" <<'EOF'
---
name: license-audit
description: routed via global config
concurrency: read
---
EOF
  cd "$gp"; git init -q
  local out; out=$(HOME="$gh" NANOSTACK_STORE="$gp/.nanostack" "$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "global config: routing.declared = true" "true"   "$(echo "$out" | jq -r '.routing.declared')"
  nh_assert_eq "global config: routing.trust = strict"  "strict" "$(echo "$out" | jq -r '.routing.trust')"
}

# Cell 7c: diarization paths are literal substrings, not regex.
cell_diar_literal() {
  routing_project "cell7c-literal" >/dev/null
  printf '%s\n' '---' 'subject: app/users/[id]/page.tsx' 'date: 2026-04-01' '---' > "$NANOSTACK_STORE/know-how/diarizations/exact.md"
  printf '%s\n' '---' 'subject: app/users/i/page.tsx' 'date: 2026-04-01' '---' > "$NANOSTACK_STORE/know-how/diarizations/decoy.md"
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"diarizations":{"paths":["app/users/[id]/page.tsx"],"keywords":[]}}}}
EOF
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "literal match: only the exact subject is loaded" \
    '["app/users/[id]/page.tsx"]' "$(echo "$out" | jq -c '.diarizations | map(.subject) | sort')"
}

# Cell 7d: solution_tags are also matched literally, not as regex.
cell_tag_literal() {
  routing_project "cell7d-tag-literal" >/dev/null
  printf '%s\n' '---' 'tags: [next.js]' '---' 'next.js notes' > "$NANOSTACK_STORE/know-how/solutions/exact.md"
  printf '%s\n' '---' 'tags: [nextxjs]' '---' 'nextxjs notes' > "$NANOSTACK_STORE/know-how/solutions/decoy.md"
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"solutions":{"tags":["next.js"],"limit":5}}}}
EOF
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "literal tag: only the exact tag file matches" "1" "$(echo "$out" | jq '.solutions | length')"
  nh_assert_contains "selected solution is exact.md" "$(echo "$out" | jq -r '.solutions[0] // ""')" "exact.md"
}

# Cell 7e: diarization subjects with JSON metacharacters parse cleanly.
cell_json_safe() {
  routing_project "cell7e-json-safe" >/dev/null
  printf '%s\n' '---' 'subject: app/"weird"/path.tsx' 'date: 2026-04-01' '---' > "$NANOSTACK_STORE/know-how/diarizations/quoted.md"
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"diarizations":{"paths":["weird"],"keywords":[]}}}}
EOF
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "quote in subject lands intact" 'app/"weird"/path.tsx' "$(echo "$out" | jq -r '.diarizations[0].subject // ""')"
}

# Cell 8: routing block surfaces every applied field.
cell_routing_shape() {
  routing_project "cell8-routing-shape" >/dev/null
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"trust":"strict","upstream_required":["review"],"upstream_optional":["security"],"max_age_days":7,"solutions":{"tags":["compliance"],"limit":3},"diarizations":{"paths":["src/privacy"],"keywords":["pii"]}}}}
EOF
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "routing.declared = true" "true" "$(echo "$out" | jq -r '.routing.declared')"
  nh_assert_eq "routing.trust = strict" "strict" "$(echo "$out" | jq -r '.routing.trust')"
  nh_assert_eq "routing.upstream_required" '["review"]' "$(echo "$out" | jq -c '.routing.upstream_required')"
  nh_assert_eq "routing.upstream_optional" '["security"]' "$(echo "$out" | jq -c '.routing.upstream_optional')"
  nh_assert_eq "routing.max_age_days" "7" "$(echo "$out" | jq -r '.routing.max_age_days')"
  nh_assert_eq "routing.solutions.tags" '["compliance"]' "$(echo "$out" | jq -c '.routing.solutions.tags')"
  nh_assert_eq "routing.solutions.limit" "3" "$(echo "$out" | jq -r '.routing.solutions.limit')"
  nh_assert_eq "routing.diarizations.paths" '["src/privacy"]' "$(echo "$out" | jq -c '.routing.diarizations.paths')"
  nh_assert_eq "routing.diarizations.keywords" '["pii"]' "$(echo "$out" | jq -c '.routing.diarizations.keywords')"
}

# Cell 8a: routing.solutions.limit reports the documented default.
cell_default_limit() {
  routing_project "cell8a-default-limit" >/dev/null
  cat > "$NANOSTACK_STORE/config.json" <<'EOF'
{"custom_phases":["license-audit"],"phase_context":{"license-audit":{"solutions":{"tags":["any"]}}}}
EOF
  local out; out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "limit omitted with tags declared reports default 10" "10" "$(echo "$out" | jq -r '.routing.solutions.limit')"
  routing_project "cell8a-no-context" >/dev/null
  printf '%s\n' '{"custom_phases": ["license-audit"]}' > "$NANOSTACK_STORE/config.json"
  out=$("$RESOLVE" license-audit 2>/dev/null)
  nh_assert_eq "no phase_context: routing.solutions.limit stays null" "null" "$(echo "$out" | jq -r '.routing.solutions.limit')"
}

nh_cell backcompat        cell_backcompat
nh_cell missing-required  cell_missing_required
nh_cell strict-drops      cell_strict_drops
nh_cell normal-keeps      cell_normal_keeps
nh_cell max-age           cell_max_age
nh_cell solution-tags     cell_solution_tags
nh_cell diarization-paths cell_diarization_paths
nh_cell routed-only       cell_routed_only
nh_cell global-config     cell_global_config
nh_cell diar-literal      cell_diar_literal
nh_cell tag-literal       cell_tag_literal
nh_cell json-safe         cell_json_safe
nh_cell routing-shape     cell_routing_shape
nh_cell default-limit     cell_default_limit

nh_summary
