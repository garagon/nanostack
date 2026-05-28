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
# Migrated onto ci/lib/harness.sh (Harness Architecture vNext PR 1).
# Same cells, same check count. Supports --filter <pattern>.
#
# Exit 0 = all cells pass, exit 1 = any cell failed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/ci/lib/harness.sh"

CHECK_DANGEROUS="$REPO/guard/bin/check-dangerous.sh"
CHECK_WRITE="$REPO/guard/bin/check-write.sh"
SESSION_SH="$REPO/bin/session.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --filter) nh_set_filter "${2:-}"; shift 2 ;;
    --filter=*) nh_set_filter "${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# Temp root lives under /tmp, not $TMPDIR: on macOS $TMPDIR is
# /var/folders/..., and check-write.sh correctly denies any path under
# /var/, which would make every "Write allowed" assertion a false
# failure unrelated to phase concurrency. nh_init enforces the /tmp root.
nh_init concurrency-parity nano-parity
nh_require_cmd git jq

WORK="$NH_TMP"
cd "$WORK"
git init -q
git config user.email t@t.t; git config user.name t
export NANOSTACK_STORE="$WORK/.nanostack"
mkdir -p "$NANOSTACK_STORE"

# A non-secret, in-project target the secret/system denylist allows, so
# any block we observe is the read-only-phase rule, not the denylist.
SAFE_PATH="$WORK/src/feature.txt"
mkdir -p "$WORK/src"

# Run check-write.sh with a hook-shaped JSON payload for a given tool.
write_hook() {
  local tool="$1" path="$2"
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool" "$path" \
    | "$CHECK_WRITE" >/dev/null 2>&1
}
bash_hook() { (cd "$WORK" && "$CHECK_DANGEROUS" "$1" >/dev/null 2>&1); }

write_session_review() {
  printf '{"workspace":"%s","current_phase":"review","phase_log":[{"phase":"review","status":"in_progress"}]}' \
    "$WORK" > "$NANOSTACK_STORE/session.json"
}

# Cells 1-4: built-in read-only phase (review) blocks every mutation tool.
cell_builtin_read() {
  write_session_review
  nh_assert_exit "Bash 'touch' blocked during review" 1 bash_hook 'touch ./src/feature.txt'
  nh_assert_exit "Write blocked during review"        1 write_hook Write     "$SAFE_PATH"
  nh_assert_exit "Edit blocked during review"         1 write_hook Edit      "$SAFE_PATH"
  nh_assert_exit "MultiEdit blocked during review"    1 write_hook MultiEdit "$SAFE_PATH"
}

# Cell 5: after phase-complete, Write is allowed again.
cell_phase_complete() {
  write_session_review
  "$SESSION_SH" phase-complete review >/dev/null 2>&1 || true
  local curr
  curr=$(jq -r '.current_phase // "null"' "$NANOSTACK_STORE/session.json" 2>/dev/null)
  nh_assert_eq "current_phase cleared after phase-complete" "null" "$curr"
  nh_assert_exit "Write allowed once review completes" 0 write_hook Write "$SAFE_PATH"
}

# Cells 6-7: registry-driven — custom phases get the same treatment (sabotage).
cell_custom_phases() {
  mkdir -p "$NANOSTACK_STORE/skills/audit-ro" "$NANOSTACK_STORE/skills/audit-rw"
  printf '%s\n' '---' 'name: audit-ro' 'description: read-only custom phase' 'concurrency: read' '---' 'Body.' \
    > "$NANOSTACK_STORE/skills/audit-ro/SKILL.md"
  printf '%s\n' '---' 'name: audit-rw' 'description: writing custom phase' 'concurrency: write' '---' 'Body.' \
    > "$NANOSTACK_STORE/skills/audit-rw/SKILL.md"
  printf '{"custom_phases":["audit-ro","audit-rw"]}' > "$NANOSTACK_STORE/config.json"

  printf '{"workspace":"%s","current_phase":"audit-ro","phase_log":[{"phase":"audit-ro","status":"in_progress"}]}' \
    "$WORK" > "$NANOSTACK_STORE/session.json"
  nh_assert_exit "custom concurrency=read phase blocks Write" 1 write_hook Write "$SAFE_PATH"

  printf '{"workspace":"%s","current_phase":"audit-rw","phase_log":[{"phase":"audit-rw","status":"in_progress"}]}' \
    "$WORK" > "$NANOSTACK_STORE/session.json"
  nh_assert_exit "custom concurrency=write phase does NOT block Write" 0 write_hook Write "$SAFE_PATH"
}

# Cell 8: no active session preserves prior allow/deny behavior.
cell_no_session() {
  rm -f "$NANOSTACK_STORE/session.json"
  nh_assert_exit "no session: in-project Write allowed"      0 write_hook Write "$SAFE_PATH"
  nh_assert_exit "no session: secret-path Write still denied" 1 write_hook Write "$WORK/.env"
}

nh_cell builtin-read    cell_builtin_read
nh_cell phase-complete  cell_phase_complete
nh_cell custom-phases   cell_custom_phases
nh_cell no-session      cell_no_session

nh_summary
