#!/usr/bin/env bash
# e2e-concurrency-parity.sh — Read-only phase write parity across guards.
#
# The phase-concurrency model lets /conductor run /review, /qa, and
# /security as one parallel batch precisely because they declare
# `concurrency: read` and therefore mutate nothing. That guarantee is
# only real if BOTH guard hooks enforce it:
#   - guard/bin/check-dangerous.sh  (Bash tool)
#   - guard/bin/check-write.sh      (Write / Edit / MultiEdit tools)
#
# Before this suite, the Bash guard blocked write-like commands during a
# read-only phase but the Write/Edit guard had no phase awareness, so an
# agent could mutate files through the primary write path while a
# read-only phase was active. Both hooks now consume the same
# nano_active_phase_concurrency helper (bin/lib/phases.sh). This suite is
# the regression lock — including sabotage cells proving the block is
# registry-driven (custom phases) rather than a hardcoded built-in list.
#
# Exit 0 = all cells pass, exit 1 = any cell failed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DANGEROUS="$REPO/guard/bin/check-dangerous.sh"
CHECK_WRITE="$REPO/guard/bin/check-write.sh"
SESSION_SH="$REPO/bin/session.sh"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[0;90m'; NC=$'\033[0m'
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '    %sOK%s    %s\n' "$GREEN" "$NC" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '    %sFAIL%s  %s\n' "$RED" "$NC" "$1"; }

# Run check-write.sh with a hook-shaped JSON payload for a given tool.
write_hook() {
  local tool="$1" path="$2"
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool" "$path" \
    | "$CHECK_WRITE" >/dev/null 2>&1
}
bash_hook() { (cd "$WORK" && "$CHECK_DANGEROUS" "$1" >/dev/null 2>&1); }

assert_exit() {
  local want="$1" got="$2" label="$3"
  if [ "$got" = "$want" ]; then ok "$label (exit $got)"; else bad "$label (want $want, got $got)"; fi
}

# ─── Workspace + store fixture ──────────────────────────────────────────
# Use /tmp/ explicitly, not $TMPDIR. On macOS $TMPDIR resolves to
# /var/folders/..., and check-write.sh correctly denies any path under
# /var/ — which would make every "Write allowed" assertion fail with a
# false positive unrelated to phase concurrency. /tmp resolves to
# /private/tmp on macOS, outside /var/. (Same workaround as
# ci/e2e-user-flows.sh.)
WORK="$(mktemp -d /tmp/nano-parity.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
git init -q
git config user.email t@t.t; git config user.name t
export NANOSTACK_STORE="$WORK/.nanostack"
mkdir -p "$NANOSTACK_STORE"

# A non-secret, in-project target the secret/system denylist allows, so
# any block we observe is the read-only-phase rule, not the denylist.
SAFE_PATH="$WORK/src/feature.txt"
mkdir -p "$WORK/src"

write_session_review() {
  printf '{"workspace":"%s","current_phase":"review","phase_log":[{"phase":"review","status":"in_progress"}]}' \
    "$WORK" > "$NANOSTACK_STORE/session.json"
}

echo
echo "${DIM}Cells 1-4: built-in read-only phase (review) blocks every mutation tool${NC}"
write_session_review
assert_exit 1 "$(bash_hook 'touch ./src/feature.txt'; echo $?)" "Bash 'touch' blocked during review"
assert_exit 1 "$(write_hook Write     "$SAFE_PATH"; echo $?)"   "Write blocked during review"
assert_exit 1 "$(write_hook Edit      "$SAFE_PATH"; echo $?)"   "Edit blocked during review"
assert_exit 1 "$(write_hook MultiEdit "$SAFE_PATH"; echo $?)"   "MultiEdit blocked during review"

echo
echo "${DIM}Cell 5: after phase-complete, Write is allowed again${NC}"
write_session_review
"$SESSION_SH" phase-complete review >/dev/null 2>&1 || true
CURR=$(jq -r '.current_phase // "null"' "$NANOSTACK_STORE/session.json" 2>/dev/null)
if [ "$CURR" = "null" ]; then ok "current_phase cleared after phase-complete"; else bad "current_phase still '$CURR' after phase-complete"; fi
assert_exit 0 "$(write_hook Write "$SAFE_PATH"; echo $?)" "Write allowed once review completes"

echo
echo "${DIM}Cells 6-7: registry-driven — custom phases get the same treatment (sabotage)${NC}"
# Register two custom phases with opposite concurrency declarations.
mkdir -p "$NANOSTACK_STORE/skills/audit-ro" "$NANOSTACK_STORE/skills/audit-rw"
printf '%s\n' '---' 'name: audit-ro' 'description: read-only custom phase' 'concurrency: read' '---' 'Body.' \
  > "$NANOSTACK_STORE/skills/audit-ro/SKILL.md"
printf '%s\n' '---' 'name: audit-rw' 'description: writing custom phase' 'concurrency: write' '---' 'Body.' \
  > "$NANOSTACK_STORE/skills/audit-rw/SKILL.md"
printf '{"custom_phases":["audit-ro","audit-rw"]}' > "$NANOSTACK_STORE/config.json"

printf '{"workspace":"%s","current_phase":"audit-ro","phase_log":[{"phase":"audit-ro","status":"in_progress"}]}' \
  "$WORK" > "$NANOSTACK_STORE/session.json"
assert_exit 1 "$(write_hook Write "$SAFE_PATH"; echo $?)" "custom concurrency=read phase blocks Write"

printf '{"workspace":"%s","current_phase":"audit-rw","phase_log":[{"phase":"audit-rw","status":"in_progress"}]}' \
  "$WORK" > "$NANOSTACK_STORE/session.json"
assert_exit 0 "$(write_hook Write "$SAFE_PATH"; echo $?)" "custom concurrency=write phase does NOT block Write"

echo
echo "${DIM}Cell 8: no active session preserves prior allow/deny behavior${NC}"
rm -f "$NANOSTACK_STORE/session.json"
assert_exit 0 "$(write_hook Write "$SAFE_PATH"; echo $?)" "no session: in-project Write allowed"
assert_exit 1 "$(write_hook Write "$WORK/.env"; echo $?)" "no session: secret-path Write still denied"

echo
echo "======================="
if [ "$FAIL" -eq 0 ]; then
  printf '%sConcurrency Parity E2E: %s checks passed, 0 failed%s\n' "$GREEN" "$PASS" "$NC"
  exit 0
else
  printf '%sConcurrency Parity E2E: %s passed, %s FAILED%s\n' "$RED" "$PASS" "$FAIL" "$NC"
  exit 1
fi
