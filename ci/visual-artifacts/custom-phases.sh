# custom-phases.sh — sourced by ci/e2e-visual-artifacts.sh (Harness vNext PR 4 split).
# Cell bodies only; shared helpers/fixtures + summary live in the driver.

# ─── Cell 22c: journal includes custom phases from registry (PR 3 pass 1) ─
printf "\n  ${DIM}Cell 22c: journal lists custom phases (PR 3 pass 1)${NC}\n"
PROJ="$TMP_ROOT/cell22c"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
cat > "$NANOSTACK_STORE/config.json" <<'CFG'
{
  "schema_version": "1",
  "custom_phases": ["license-audit", "privacy-check"]
}
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_contains "journal lists custom license-audit row" "$HTML" 'data-phase="license-audit"'
assert_contains "journal lists custom privacy-check row" "$HTML" 'data-phase="privacy-check"'

# ─── Cell 25a: registered custom phase renders (VA-CUSTOM-001) ─
# Architect retest 2026-05-11: bin/render-artifact.sh used to exit 1
# with "unsupported phase: license-audit" for legitimate custom
# phase artifacts. The renderer now dispatches them through the
# generic custom-phase body, writes to visual/custom/<phase>/, and
# records custom_phase: true in the manifest.
printf "\n  ${DIM}Cell 25a: registered custom phase renders (VA-CUSTOM-001)${NC}\n"
PROJ="$TMP_ROOT/cell25a"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
register_custom_phase "$NANOSTACK_STORE" "license-audit"
(cd "$PROJ" && save_valid_custom "$NANOSTACK_STORE" "license-audit")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" license-audit --latest)
assert_true "custom phase html exists" test -f "$HTML"
case "$HTML" in
  */visual/custom/license-audit/*)
    PASS=$((PASS+1)); printf "    ${GREEN}OK${NC}    output lands under visual/custom/license-audit/\n" ;;
  *)
    FAIL=$((FAIL+1)); printf "    ${RED}FAIL${NC}  custom path: %s\n" "$HTML" ;;
esac
assert_contains "data-phase = license-audit" "$HTML" 'data-phase="license-audit"'
assert_contains "custom phase headline renders" "$HTML" "all licenses approved"
assert_contains "custom phase status chip renders" "$HTML" ">OK<"
assert_contains "custom phase scalar field renders" "$HTML" "licenses_scanned"
assert_contains "custom phase finding renders" "$HTML" "LIC-001"
assert_contains "custom phase finding description" "$HTML" "GPL-3.0 in subdep"
assert_contains "raw JSON details block present" "$HTML" 'data-testid="custom-raw-json"'
MFST=$(ls -t "$NANOSTACK_STORE/visual/manifests/"*license-audit*.manifest.json | head -1)
assert_true "manifest exists" test -f "$MFST"
assert_true "manifest custom_phase = true" \
  sh -c "[ \"\$(jq -r .custom_phase '$MFST')\" = 'true' ]"
assert_true "manifest kind = phase" \
  sh -c "[ \"\$(jq -r .kind '$MFST')\" = 'phase' ]"
assert_true "manifest phase = license-audit" \
  sh -c "[ \"\$(jq -r .phase '$MFST')\" = 'license-audit' ]"
assert_true "manifest source trust = verified" \
  sh -c "[ \"\$(jq -r '.source_artifacts[0].trust' '$MFST')\" = 'verified' ]"
unset NANOSTACK_STORE

# ─── Cell 25b: unregistered phase remains rejected (VA-CUSTOM-001) ─
printf "\n  ${DIM}Cell 25b: unregistered phase rejected (VA-CUSTOM-001)${NC}\n"
PROJ="$TMP_ROOT/cell25b"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# No custom_phases declared. Asking for an unknown phase exits 1.
assert_exit "unknown phase 'not-registered' exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' not-registered --latest"
# Even with config.json present but the phase not listed, it must reject.
register_custom_phase "$NANOSTACK_STORE" "license-audit"
assert_exit "phase 'unknown-phase' still rejected when others are registered" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' unknown-phase --latest"
unset NANOSTACK_STORE

# ─── Cell 25c: custom phase --strict rejects integrity_missing (VA-CUSTOM-001) ─
printf "\n  ${DIM}Cell 25c: custom phase --strict trust (VA-CUSTOM-001)${NC}\n"
PROJ="$TMP_ROOT/cell25c"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
register_custom_phase "$NANOSTACK_STORE" "license-audit"
(cd "$PROJ" && save_valid_custom "$NANOSTACK_STORE" "license-audit")
ART=$(ls "$NANOSTACK_STORE/license-audit/"*.json | head -1)
# Strip .integrity then --strict must exit 3; non-strict must render with unverified badge.
jq 'del(.integrity)' "$ART" > "$ART.tmp" && mv "$ART.tmp" "$ART"
assert_exit "custom phase --strict on integrity_missing exits 3" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' license-audit --latest --strict"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" license-audit --latest)
assert_contains "non-strict custom phase shows unverified badge" "$HTML" 'data-trust="integrity_missing"'
assert_contains "unverified badge text" "$HTML" ">unverified<"
# Tamper case: re-save then mutate.
rm -f "$NANOSTACK_STORE/license-audit/"*.json
(cd "$PROJ" && save_valid_custom "$NANOSTACK_STORE" "license-audit")
ART=$(ls "$NANOSTACK_STORE/license-audit/"*.json | head -1)
jq '.summary.status = "TAMPERED"' "$ART" > "$ART.tmp" && mv "$ART.tmp" "$ART"
assert_exit "custom phase integrity_mismatch exits 3 even without --strict" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' license-audit --latest"
unset NANOSTACK_STORE

# ─── Cell 25d: custom phase XSS escape (VA-CUSTOM-001) ─
printf "\n  ${DIM}Cell 25d: custom phase XSS escape (VA-CUSTOM-001)${NC}\n"
PROJ="$TMP_ROOT/cell25d"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
register_custom_phase "$NANOSTACK_STORE" "audit"
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" audit '{
  "phase": "audit",
  "summary": {
    "status": "<script>alert(1)</script>",
    "headline": "<img src=x onerror=alert(2)>",
    "details": {"key": "<iframe>x</iframe>"}
  },
  "findings": [
    {"id": "X", "severity": "high", "description": "\"><script>alert(3)</script>"}
  ],
  "context_checkpoint": {"summary": "x", "key_files": [], "decisions_made": [], "open_questions": []}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" audit --latest)
assert_not_contains "no raw <script>alert(1)" "$HTML" '<script>alert(1)'
assert_not_contains "no raw <script>alert(3)" "$HTML" '<script>alert(3)'
assert_not_contains "no raw <iframe>x" "$HTML" '<iframe>x</iframe>'
assert_not_contains "no raw <img src=x onerror" "$HTML" '<img src=x onerror'
assert_contains "escaped script tag" "$HTML" '&lt;script&gt;'
assert_contains "escaped iframe tag" "$HTML" '&lt;iframe&gt;'
unset NANOSTACK_STORE

# ─── Cell 25e: custom phase --interactive rejected (VA-CUSTOM-001) ─
printf "\n  ${DIM}Cell 25e: custom phase --interactive rejected (VA-CUSTOM-001)${NC}\n"
PROJ="$TMP_ROOT/cell25e"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
register_custom_phase "$NANOSTACK_STORE" "license-audit"
(cd "$PROJ" && save_valid_custom "$NANOSTACK_STORE" "license-audit")
assert_exit "custom phase --interactive exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' license-audit --latest --interactive"
unset NANOSTACK_STORE

