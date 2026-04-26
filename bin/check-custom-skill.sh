#!/usr/bin/env bash
# check-custom-skill.sh — Validate a copied or scaffolded custom skill.
#
# Usage: bin/check-custom-skill.sh <skill-dir>
#
# Checks that the spec's PR 6 contract holds for one custom skill:
#   1. SKILL.md exists with required frontmatter (name, description,
#      concurrency in {read, write, exclusive}).
#   2. agents/openai.yaml exists and parses as YAML.
#   3. bin/*.sh passes bash -n.
#   4. The skill name matches the directory name and the registry's
#      phase-name regex.
#   5. The phase is registered in .nanostack/config.json:custom_phases
#      so save-artifact.sh / resolve.sh accept it.
#   6. SKILL.md does not embed ./examples/custom-skill-template/...
#      paths (would break after copy).
#   7. The skill can save an artifact and find-artifact.sh can read it
#      back. Smoke artifact is removed after the check.
#
# Output: one OK or FAIL line per check. Exit 0 if all pass, 1 if any
# fail. The output is plain text by design — this is a CLI tool,
# Professional voice, no profile-aware skeleton.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NANOSTACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Resolve NANOSTACK_STORE the same way lifecycle scripts do, so that
# the registry sees the project's .custom_phases without forcing the
# user to export the env var manually.
. "$SCRIPT_DIR/lib/store-path.sh"
. "$SCRIPT_DIR/lib/phases.sh"

SKILL_DIR="${1:-}"
if [ -z "$SKILL_DIR" ]; then
  echo "Usage: bin/check-custom-skill.sh <skill-dir>" >&2
  exit 2
fi
if [ ! -d "$SKILL_DIR" ]; then
  echo "ERROR: $SKILL_DIR is not a directory" >&2
  exit 2
fi

PASS=0
FAIL=0
report() {
  local status="$1" name="$2"
  if [ "$status" = "OK" ]; then
    printf '  OK    %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

NAME=$(basename "$SKILL_DIR")

# 1. SKILL.md + frontmatter
SKILL_MD="$SKILL_DIR/SKILL.md"
if [ ! -f "$SKILL_MD" ]; then
  report FAIL "SKILL.md exists at $SKILL_MD"
else
  report OK "SKILL.md exists"
  # Extract frontmatter region (between first two --- markers).
  fm=$(awk '/^---[[:space:]]*$/{f++; next} f==1' "$SKILL_MD")
  if echo "$fm" | grep -qE '^name:[[:space:]]'; then
    report OK "frontmatter has 'name:'"
  else
    report FAIL "frontmatter has 'name:'"
  fi
  if echo "$fm" | grep -qE '^description:[[:space:]]'; then
    report OK "frontmatter has 'description:'"
  else
    report FAIL "frontmatter has 'description:'"
  fi
  conc=$(echo "$fm" | grep -E '^concurrency:[[:space:]]' | head -1 | sed 's/^concurrency:[[:space:]]*//')
  case "$conc" in
    read|write|exclusive)
      report OK "concurrency is $conc"
      ;;
    *)
      report FAIL "concurrency is one of read|write|exclusive (found: '$conc')"
      ;;
  esac
fi

# 2. agents/openai.yaml exists and parses
OPENAI_YAML="$SKILL_DIR/agents/openai.yaml"
if [ ! -f "$OPENAI_YAML" ]; then
  report FAIL "agents/openai.yaml exists"
elif ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$OPENAI_YAML" 2>/dev/null; then
  report FAIL "agents/openai.yaml parses as YAML"
else
  report OK "agents/openai.yaml exists and parses"
fi

# 3. bin/*.sh passes bash -n
if [ -d "$SKILL_DIR/bin" ]; then
  bin_fail=0
  for s in "$SKILL_DIR/bin"/*.sh; do
    [ -f "$s" ] || continue
    if ! bash -n "$s" 2>/dev/null; then
      bin_fail=1
      report FAIL "bash -n $(basename "$s")"
    fi
  done
  [ "$bin_fail" -eq 0 ] && report OK "bin/*.sh syntax check"
else
  report OK "no bin/ to check"
fi

# 4. Skill directory name matches the registry regex.
if printf '%s' "$NAME" | grep -qE "$NANO_PHASE_NAME_RE"; then
  report OK "skill name '$NAME' matches phase regex"
else
  report FAIL "skill name '$NAME' matches phase regex (^[a-z][a-z0-9-]*$)"
fi

# 5. Phase is registered.
if nano_phase_exists "$NAME" 2>/dev/null; then
  report OK "phase '$NAME' is registered in .nanostack/config.json"
else
  report FAIL "phase '$NAME' is registered in .nanostack/config.json (use bin/create-skill.sh --register or edit config.custom_phases)"
fi

# 6. No repo-relative example paths leaked into SKILL.md.
if [ -f "$SKILL_MD" ]; then
  if grep -qE '\./examples/custom-skill-template/' "$SKILL_MD"; then
    report FAIL "SKILL.md does not reference ./examples/custom-skill-template/"
  else
    report OK "SKILL.md has no repo-relative example paths"
  fi
fi

# 7. Save + read smoke artifact (only if registered, otherwise the save
#    will rightfully fail and we already reported the registration FAIL
#    above).
if nano_phase_exists "$NAME" 2>/dev/null; then
  store="${NANOSTACK_STORE:-$PWD/.nanostack}"
  export NANOSTACK_STORE="$store"
  smoke_dir="$store/$NAME"
  smoke_before=$(ls "$smoke_dir" 2>/dev/null | wc -l | tr -d ' ')
  if "$NANOSTACK_ROOT/bin/save-artifact.sh" "$NAME" \
    "{\"phase\":\"$NAME\",\"summary\":{\"status\":\"OK\",\"headline\":\"check-custom-skill smoke\"},\"context_checkpoint\":{\"summary\":\"smoke save\"}}" \
    >/dev/null 2>&1; then
    report OK "save-artifact accepts the skill name"
  else
    report FAIL "save-artifact accepts the skill name"
  fi
  found=$("$NANOSTACK_ROOT/bin/find-artifact.sh" "$NAME" 1 2>/dev/null) || found=""
  if [ -n "$found" ] && [ -f "$found" ]; then
    report OK "find-artifact returns the saved smoke artifact"
    # Clean up: remove only the smoke file we just wrote.
    rm -f "$found"
  else
    report FAIL "find-artifact returns the saved smoke artifact"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK: $NAME passed $PASS checks."
else
  echo "FAIL: $FAIL of $((PASS + FAIL)) checks failed for $NAME."
fi
exit $FAIL
