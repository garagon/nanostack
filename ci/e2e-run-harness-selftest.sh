#!/usr/bin/env bash
# e2e-run-harness-selftest.sh — run-harness.sh check-floor sabotage test.
#
# run-harness.sh enforces the manifest's expected_checks as a floor: a
# suite that exits 0 but reports fewer checks than declared (or no
# parseable summary at all) counts as a failure, because exit codes
# alone cannot catch a suite that silently skips cells. Like the
# manifest selftest, this proves the enforcement fails closed on each
# drift direction, using fixture suites under a throwaway manifest via
# the NANOSTACK_HARNESS_MANIFEST hook, so a future refactor of
# run-harness.sh cannot quietly turn the floor into a no-op.
#
# Exit 0 = all cells pass, exit 1 = any cell failed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/ci/lib/harness.sh"

RUN_HARNESS="$REPO/ci/run-harness.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --filter) nh_set_filter "${2:-}"; shift 2 ;;
    --filter=*) nh_set_filter "${1#*=}"; shift ;;
    *) shift ;;
  esac
done

nh_init run-harness-selftest nano-rhself
nh_require_cmd jq

FIX="$NH_TMP/fixtures"
mkdir -p "$FIX"

# A fixture suite that reports a configurable count, plus one that
# prints no summary at all. Both always exit 0; only the floor logic
# can flag them.
cat > "$FIX/reports.sh" <<'EOF'
#!/usr/bin/env bash
echo "running ${REPORT_N:-0} fixture checks"
echo "fixture: ${REPORT_N:-0} checks passed, 0 failed"
exit 0
EOF
cat > "$FIX/silent.sh" <<'EOF'
#!/usr/bin/env bash
echo "fixture finished without a summary"
exit 0
EOF
# A fixture that echoes a count-shaped phrase mid-run; only the final
# summary may be parsed.
cat > "$FIX/noisy.sh" <<'EOF'
#!/usr/bin/env bash
echo "replaying log: 999 checks passed earlier today"
echo "padding line one"
echo "padding line two"
echo "padding line three"
echo "padding line four"
echo "fixture: 3 checks passed, 0 failed"
exit 0
EOF
chmod +x "$FIX"/*.sh

write_manifest() {  # $1 = suite path, $2 = expected_checks
  jq -n --arg p "$1" --argjson e "$2" '{
    schema_version: 1,
    suites: [{id:"fixture", path:$p, kind:"unit", tier:"pr",
              surface:["fixture"], deps:["bash"], expected_checks:$e,
              timeout_minutes:1, workflow:"none", job:"none"}]
  }' > "$NH_TMP/manifest.json"
  export NANOSTACK_HARNESS_MANIFEST="$NH_TMP/manifest.json"
}

run_fixture() {  # extra run-harness args after --suite fixture
  nh_capture RH_OUT RH_RC bash "$RUN_HARNESS" --suite fixture "$@"
}

cell_floor_enforced() {
  write_manifest "$FIX/reports.sh" 10

  REPORT_N=10 run_fixture
  nh_assert_eq "count at the floor passes" 0 "$RH_RC"

  REPORT_N=5 run_fixture
  nh_assert_eq "count below the floor fails" 1 "$RH_RC"
  nh_assert_contains "below-floor run names the floor" "$RH_OUT" "below the manifest floor of 10"

  REPORT_N=12 run_fixture
  nh_assert_eq "count above the floor still passes" 0 "$RH_RC"
  nh_assert_contains "above-floor run asks for a manifest bump" "$RH_OUT" "update expected_checks"
}

cell_no_summary() {
  write_manifest "$FIX/silent.sh" 10
  run_fixture
  nh_assert_eq "missing summary fails when a floor is declared" 1 "$RH_RC"
  nh_assert_contains "missing-summary run says so" "$RH_OUT" "no parseable check count"

  write_manifest "$FIX/silent.sh" 0
  run_fixture
  nh_assert_eq "expected_checks 0 keeps unparseable suites exempt" 0 "$RH_RC"
}

cell_filter_exempt() {
  # Filtering runs fewer cells by design, so the floor must not apply.
  write_manifest "$FIX/reports.sh" 10
  REPORT_N=2 run_fixture --filter anything
  nh_assert_eq "filtered run skips the floor" 0 "$RH_RC"
}

cell_final_summary_wins() {
  # The count comes from the end of the output: a count-shaped phrase
  # echoed mid-run must not satisfy (or inflate past) the floor.
  write_manifest "$FIX/noisy.sh" 3
  run_fixture
  nh_assert_eq "final summary line is the parsed count" 0 "$RH_RC"
  write_manifest "$FIX/noisy.sh" 4
  run_fixture
  nh_assert_eq "mid-run 999 does not satisfy a floor of 4" 1 "$RH_RC"
}

nh_cell floor-enforced cell_floor_enforced
nh_cell no-summary cell_no_summary
nh_cell filter-exempt cell_filter_exempt
nh_cell final-summary-wins cell_final_summary_wins

nh_summary
