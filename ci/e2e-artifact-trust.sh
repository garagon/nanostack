#!/usr/bin/env bash
# e2e-artifact-trust.sh — Artifact Trust v2 contract.
#
# Locks the shared trust model introduced in PR 2 of the 2026-05-10
# architecture audit, plus the PR 3 phase-gate trusted-evidence contract
# (2026-05-28). Covers the four canonical artifact states across
# bin/lib/artifact-trust.sh, bin/find-artifact.sh (--verify and
# --require-integrity), bin/resolve.sh (upstream_status), and
# guard/bin/phase-gate.sh (commit/push gate consumes trusted, filename-
# dated evidence).
#
# Migrated onto ci/lib/harness.sh + ci/lib/fixtures.sh (Harness vNext
# PR 2). Same cells, same check count (41). Artifacts are built via
# nf_write_artifact, whose "verified" hash is the production canonical
# hash, so a fixture verifies exactly as a save-artifact.sh output would.
# Supports --filter <pattern>.
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

nh_init artifact-trust nanostack-artifact-trust
nh_require_cmd git jq

FIND="$REPO/bin/find-artifact.sh"
RESOLVE="$REPO/bin/resolve.sh"
GATE="$REPO/guard/bin/phase-gate.sh"

# Cell 1: nano_artifact_trust returns each of the four statuses.
cell_trust_statuses() {
  local store; store=$(nf_new_store "$(nf_new_git_project trust1)")
  nf_write_artifact "$store" trust verified  2026-05-10T01-00-00 "$store" >/dev/null
  nf_write_artifact "$store" trust integrity_missing  2026-05-10T01-01-00 "$store" >/dev/null
  nf_write_artifact "$store" trust integrity_mismatch 2026-05-10T01-02-00 "$store" >/dev/null
  local ok miss bad none
  ok=$(bash -c "source '$REPO/bin/lib/artifact-trust.sh'; nano_artifact_trust '$store/trust/2026-05-10T01-00-00.json'")
  miss=$(bash -c "source '$REPO/bin/lib/artifact-trust.sh'; nano_artifact_trust '$store/trust/2026-05-10T01-01-00.json'")
  bad=$(bash -c "source '$REPO/bin/lib/artifact-trust.sh'; nano_artifact_trust '$store/trust/2026-05-10T01-02-00.json'")
  none=$(bash -c "source '$REPO/bin/lib/artifact-trust.sh'; nano_artifact_trust '$store/trust/does-not-exist.json' || true")
  nh_assert_eq "verified artifact"           "verified"           "$ok"
  nh_assert_eq "integrity_missing artifact"  "integrity_missing"  "$miss"
  nh_assert_eq "integrity_mismatch artifact" "integrity_mismatch" "$bad"
  nh_assert_eq "not_found artifact"          "not_found"          "$none"
}

# Cell 2: find-artifact.sh default returns the newest regardless of trust.
cell_find_default() {
  local proj store; proj=$(nf_new_git_project trust2); store=$(nf_new_store "$proj"); cd "$proj"
  nf_write_artifact "$store" trust verified           2026-05-10T01-00-00 "$proj" >/dev/null
  nf_write_artifact "$store" trust integrity_mismatch 2026-05-10T01-02-00 "$proj" >/dev/null
  local out
  out=$( NANOSTACK_STORE="$store" "$FIND" trust 30 2>/dev/null || true )
  nh_assert_eq "default returns the newest (mismatch) artifact" "2026-05-10T01-02-00.json" "$(basename "${out:-}")"
}

# Cell 3: find-artifact.sh --verify is lenient on missing integrity.
cell_find_verify_lenient() {
  local proj store; proj=$(nf_new_git_project trust3); store=$(nf_new_store "$proj"); cd "$proj"
  local out rc
  nf_write_artifact "$store" review verified 2026-05-10T02-00-00 "$proj" >/dev/null
  nh_capture out rc env NANOSTACK_STORE="$store" "$FIND" review 30 --verify
  nh_assert_eq "verified passes --verify (rc 0)" "0" "$rc"
  nh_assert_eq "verified path returned" "2026-05-10T02-00-00.json" "$(basename "$(printf '%s\n' "$out" | tail -1)")"
  nf_write_artifact "$store" review integrity_missing 2026-05-10T02-01-00 "$proj" >/dev/null
  nh_capture out rc env NANOSTACK_STORE="$store" "$FIND" review 30 --verify
  nh_assert_eq "integrity_missing passes --verify (rc 0)" "0" "$rc"
  nh_assert_eq "newest missing-integrity path returned" "2026-05-10T02-01-00.json" "$(basename "$(printf '%s\n' "$out" | tail -1)")"
  nf_write_artifact "$store" review integrity_mismatch 2026-05-10T02-02-00 "$proj" >/dev/null
  nh_capture out rc env NANOSTACK_STORE="$store" "$FIND" review 30 --verify
  nh_assert_eq "integrity_mismatch fails --verify (rc 1)" "1" "$rc"
  nh_assert_contains "stderr labelled INTEGRITY FAILED" "$out" "INTEGRITY FAILED:"
}

# Cell 4: find-artifact.sh --require-integrity is strict on missing + mismatch.
cell_find_require_integrity() {
  local proj store; proj=$(nf_new_git_project trust4); store=$(nf_new_store "$proj"); cd "$proj"
  local out rc
  nf_write_artifact "$store" qa verified 2026-05-10T03-00-00 "$proj" >/dev/null
  nh_capture out rc env NANOSTACK_STORE="$store" "$FIND" qa 30 --require-integrity
  nh_assert_eq "verified passes --require-integrity (rc 0)" "0" "$rc"
  nf_write_artifact "$store" qa integrity_missing 2026-05-10T03-01-00 "$proj" >/dev/null
  nh_capture out rc env NANOSTACK_STORE="$store" "$FIND" qa 30 --require-integrity
  nh_assert_eq "integrity_missing fails --require-integrity (rc 1)" "1" "$rc"
  nh_assert_contains "stderr labelled INTEGRITY MISSING" "$out" "INTEGRITY MISSING:"
  nf_write_artifact "$store" qa integrity_mismatch 2026-05-10T03-02-00 "$proj" >/dev/null
  nh_capture out rc env NANOSTACK_STORE="$store" "$FIND" qa 30 --require-integrity
  nh_assert_eq "integrity_mismatch fails --require-integrity (rc 1)" "1" "$rc"
}

# Cell 5: resolve.sh exposes upstream_status for every declared upstream.
cell_resolve_upstream_status() {
  local proj store; proj=$(nf_new_git_project trust5); store=$(nf_new_store "$proj"); cd "$proj"
  nf_write_artifact "$store" review   verified           2026-05-10T04-00-00 "$proj" >/dev/null
  nf_write_artifact "$store" security integrity_missing  2026-05-10T04-00-00 "$proj" >/dev/null
  nf_write_artifact "$store" qa       integrity_mismatch 2026-05-10T04-00-00 "$proj" >/dev/null
  local resolved
  resolved=$( NANOSTACK_STORE="$store" "$RESOLVE" ship 2>/dev/null )
  nh_assert_eq "upstream_status.review == verified"            "verified"           "$(echo "$resolved" | jq -r '.upstream_status.review // ""')"
  nh_assert_eq "upstream_status.security == integrity_missing" "integrity_missing"  "$(echo "$resolved" | jq -r '.upstream_status.security // ""')"
  nh_assert_eq "upstream_status.qa == integrity_mismatch"      "integrity_mismatch" "$(echo "$resolved" | jq -r '.upstream_status.qa // ""')"
}

# Cell 6: upstream_artifacts shape stays backward compatible.
cell_resolve_artifacts_shape() {
  local proj store; proj=$(nf_new_git_project trust6); store=$(nf_new_store "$proj"); cd "$proj"
  nf_write_artifact "$store" review   verified           2026-05-10T04-00-00 "$proj" >/dev/null
  nf_write_artifact "$store" security integrity_missing  2026-05-10T04-00-00 "$proj" >/dev/null
  nf_write_artifact "$store" qa       integrity_mismatch 2026-05-10T04-00-00 "$proj" >/dev/null
  local resolved
  resolved=$( NANOSTACK_STORE="$store" "$RESOLVE" ship 2>/dev/null )
  nh_assert_eq "verified artifact loads"          "yes" "$(echo "$resolved" | jq -e '.upstream_artifacts.review != null'   >/dev/null 2>&1 && echo yes || echo no)"
  nh_assert_eq "integrity_missing artifact loads" "yes" "$(echo "$resolved" | jq -e '.upstream_artifacts.security != null' >/dev/null 2>&1 && echo yes || echo no)"
  nh_assert_eq "integrity_mismatch artifact omitted from upstream_artifacts" "no" "$(echo "$resolved" | jq -e '.upstream_artifacts.qa != null' >/dev/null 2>&1 && echo yes || echo no)"
}

# Cell 7: missing upstream (never saved) is reported as "missing".
cell_resolve_missing() {
  local proj store; proj=$(nf_new_git_project trust7); store=$(nf_new_store "$proj"); cd "$proj"
  nf_write_artifact "$store" review verified 2026-05-10T05-00-00 "$proj" >/dev/null
  local resolved
  resolved=$( NANOSTACK_STORE="$store" "$RESOLVE" ship 2>/dev/null )
  nh_assert_eq "missing security reports status=missing" "missing" "$(echo "$resolved" | jq -r '.upstream_status.security // ""')"
  nh_assert_eq "missing qa reports status=missing"       "missing" "$(echo "$resolved" | jq -r '.upstream_status.qa // ""')"
}

# Cell 8a: find-artifact.sh parses flags even when max-age is omitted.
cell_find_flag_detection() {
  local proj store; proj=$(nf_new_git_project trust8a); store=$(nf_new_store "$proj"); cd "$proj"
  nf_write_artifact "$store" plan integrity_missing 2026-05-10T08-00-00 "$proj" >/dev/null
  local out rc
  nh_capture out rc env NANOSTACK_STORE="$store" "$FIND" plan --require-integrity
  nh_assert_eq "no max-age + --require-integrity fails on missing (rc 1)" "1" "$rc"
  nh_assert_contains "no max-age + --require-integrity emits INTEGRITY MISSING" "$out" "INTEGRITY MISSING:"
  nh_capture out rc env NANOSTACK_STORE="$store" "$FIND" plan --verify
  nh_assert_eq "no max-age + --verify is lenient (rc 0)" "0" "$rc"
}

# Cell 8: custom phases also get upstream_status via the dep graph.
cell_custom_upstream() {
  local proj store; proj=$(nf_new_git_project trust8); store=$(nf_new_store "$proj"); cd "$proj"
  nf_register_custom_phase "$store" license-audit read
  nf_register_phase_graph "$store" '[
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"license-audit","depends_on":["build","review"]},
    {"name":"review","depends_on":["build"]},
    {"name":"ship","depends_on":["license-audit"]}
  ]'
  nf_write_artifact "$store" review verified 2026-05-10T06-00-00 "$proj" >/dev/null
  local resolved
  resolved=$( NANOSTACK_STORE="$store" "$RESOLVE" license-audit 2>/dev/null )
  nh_assert_eq "custom phase_kind = custom"                 "custom"          "$(echo "$resolved" | jq -r '.phase_kind // ""')"
  nh_assert_eq "custom upstream_status.review = verified"   "verified"        "$(echo "$resolved" | jq -r '.upstream_status.review // ""')"
  nh_assert_eq "custom upstream_status.build = not_applicable" "not_applicable" "$(echo "$resolved" | jq -r '.upstream_status.build // ""')"
}

# ── Phase-gate trusted-evidence cells (PR 3 of 2026-05-28) ──────────────
# A project with an active session (review/security/qa enforced) + one
# commit so the last-code-change reference resolves through git log.
setup_gate_project() {
  local name="$1" proj store
  proj=$(nf_new_git_project "$name")
  store=$(nf_new_store "$proj")
  ( cd "$proj" && echo code > file.txt && git add -A && git commit -qm init ) >/dev/null 2>&1
  nf_write_session "$store" "$proj" review
  printf '%s' "$proj"
}

run_gate() {
  local proj="$1"; shift
  local store="$proj/.nanostack"
  ( cd "$proj" && env "$@" NANOSTACK_STORE="$store" "$GATE" "git commit -m x" >/dev/null 2>&1; echo "RC=$?" )
}

# Cell 9: valid trusted artifacts satisfy the gate.
cell_gate_valid() {
  local proj fresh; proj=$(setup_gate_project gate-valid); fresh=$(date -u +%Y%m%d-%H%M%S)
  nf_write_artifact "$proj/.nanostack" review   verified "$fresh" "$proj" >/dev/null
  nf_write_artifact "$proj/.nanostack" security verified "$fresh" "$proj" >/dev/null
  nf_write_artifact "$proj/.nanostack" qa       verified "$fresh" "$proj" >/dev/null
  nh_assert_eq "valid + integrity allows commit (rc 0)" "0" "$(run_gate "$proj" | sed -n 's/^RC=//p')"
}

# Cell 10: tampered (integrity_mismatch) artifact blocks.
cell_gate_mismatch() {
  local proj fresh; proj=$(setup_gate_project gate-mismatch); fresh=$(date -u +%Y%m%d-%H%M%S)
  nf_write_artifact "$proj/.nanostack" review   verified "$fresh" "$proj" >/dev/null
  nf_write_artifact "$proj/.nanostack" security verified "$fresh" "$proj" >/dev/null
  nf_write_artifact "$proj/.nanostack" qa       integrity_mismatch "$fresh" "$proj" >/dev/null
  nh_assert_eq "tampered qa artifact blocks commit (rc 1)" "1" "$(run_gate "$proj" | sed -n 's/^RC=//p')"
}

# Cell 11: missing-integrity artifact blocks.
cell_gate_missing() {
  local proj fresh; proj=$(setup_gate_project gate-missing); fresh=$(date -u +%Y%m%d-%H%M%S)
  nf_write_artifact "$proj/.nanostack" review   verified "$fresh" "$proj" >/dev/null
  nf_write_artifact "$proj/.nanostack" security integrity_missing "$fresh" "$proj" >/dev/null
  nf_write_artifact "$proj/.nanostack" qa       verified "$fresh" "$proj" >/dev/null
  nh_assert_eq "missing-integrity security artifact blocks commit (rc 1)" "1" "$(run_gate "$proj" | sed -n 's/^RC=//p')"
}

# Cell 12: an OLD artifact whose mtime is freshened does not satisfy
# freshness, because freshness reads the filename timestamp.
cell_gate_touch_old() {
  local proj old; proj=$(setup_gate_project gate-touch-old); old=20200101-000000
  nf_write_artifact "$proj/.nanostack" review   verified "$old" "$proj" >/dev/null
  nf_write_artifact "$proj/.nanostack" security verified "$old" "$proj" >/dev/null
  nf_write_artifact "$proj/.nanostack" qa       verified "$old" "$proj" >/dev/null
  touch "$proj/.nanostack/review/$old.json" "$proj/.nanostack/security/$old.json" "$proj/.nanostack/qa/$old.json"
  nh_assert_eq "touched old artifacts still block commit (rc 1)" "1" "$(run_gate "$proj" | sed -n 's/^RC=//p')"
}

# Cell 13: NANOSTACK_SKIP_GATE=1 bypasses; control confirms the same setup blocks.
cell_gate_skip() {
  local proj; proj=$(setup_gate_project gate-skip)
  nh_assert_eq "control: no artifacts blocks commit (rc 1)" "1" "$(run_gate "$proj" | sed -n 's/^RC=//p')"
  nh_assert_eq "NANOSTACK_SKIP_GATE=1 allows commit (rc 0)" "0" "$(run_gate "$proj" NANOSTACK_SKIP_GATE=1 | sed -n 's/^RC=//p')"
}

# Cell 14: impossible calendar date in the filename fails freshness closed.
cell_gate_bad_date() {
  helper_epoch() { bash -c "source '$REPO/bin/lib/portable.sh'; nano_artifact_filename_epoch '$1'"; }
  nh_assert_eq "helper: valid stamp parses to non-zero" "ok" \
    "$([ "$(helper_epoch /x/20260528-143012.json)" -gt 0 ] 2>/dev/null && echo ok || echo no)"
  nh_assert_eq "helper: Feb 31 returns 0"     "0" "$(helper_epoch /x/20260231-120000.json)"
  nh_assert_eq "helper: month 13 returns 0"   "0" "$(helper_epoch /x/20261301-120000.json)"
  nh_assert_eq "helper: hour 25 returns 0"    "0" "$(helper_epoch /x/20260528-250000.json)"
  nh_assert_eq "helper: non-canonical name 0" "0" "$(helper_epoch /x/2026-05-10T01-00-00.json)"
  local proj bad; proj=$(setup_gate_project gate-bad-date); bad=20990231-120000
  nf_write_artifact "$proj/.nanostack" review   verified "$bad" "$proj" >/dev/null
  nf_write_artifact "$proj/.nanostack" security verified "$bad" "$proj" >/dev/null
  nf_write_artifact "$proj/.nanostack" qa       verified "$bad" "$proj" >/dev/null
  nh_assert_eq "impossible-date artifact blocks commit (rc 1)" "1" "$(run_gate "$proj" | sed -n 's/^RC=//p')"
}

nh_cell trust-statuses        cell_trust_statuses
nh_cell find-default          cell_find_default
nh_cell find-verify-lenient   cell_find_verify_lenient
nh_cell find-require-integrity cell_find_require_integrity
nh_cell resolve-upstream-status cell_resolve_upstream_status
nh_cell resolve-artifacts-shape cell_resolve_artifacts_shape
nh_cell resolve-missing       cell_resolve_missing
nh_cell find-flag-detection   cell_find_flag_detection
nh_cell custom-upstream       cell_custom_upstream
nh_cell gate-valid            cell_gate_valid
nh_cell gate-mismatch         cell_gate_mismatch
nh_cell gate-missing          cell_gate_missing
nh_cell gate-touch-old        cell_gate_touch_old
nh_cell gate-skip             cell_gate_skip
nh_cell gate-bad-date         cell_gate_bad_date

nh_summary
