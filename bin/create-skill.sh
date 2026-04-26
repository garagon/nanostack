#!/usr/bin/env bash
# create-skill.sh — Scaffold a custom nanostack skill.
#
# Usage:
#   bin/create-skill.sh <name> \
#     [--from <template-dir>] \
#     [--concurrency <read|write|exclusive>] \
#     [--depends-on <phase>]... \
#     [--register | --no-register]
#
# Defaults:
#   --from        examples/custom-skill-template/audit-licenses
#   --concurrency keeps the template's frontmatter value
#   --depends-on  empty list
#   --register    true (omits the registration step with --no-register)
#
# Output:
#   Creates .nanostack/skills/<name>/ with SKILL.md, agents/openai.yaml,
#   and the template's bin/ helpers. Substitutes the source skill name
#   with <name> inside SKILL.md and agents/openai.yaml. Adds <name> to
#   .custom_phases in .nanostack/config.json unless --no-register.
#
# Prints one next-step line on success.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NANOSTACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Resolve NANOSTACK_STORE the same way lifecycle scripts do, so a
# skill scaffolded from a git subdirectory or a no-git project lands
# where save-artifact / resolve / conductor will look for it.
. "$SCRIPT_DIR/lib/store-path.sh"
. "$SCRIPT_DIR/lib/phases.sh"

NAME="${1:-}"
if [ -z "$NAME" ] || [ "${NAME#--}" != "$NAME" ]; then
  echo "Usage: bin/create-skill.sh <name> [--from <dir>] [--concurrency <read|write|exclusive>] [--depends-on <phase>]... [--register | --no-register]" >&2
  exit 2
fi
shift

if ! printf '%s' "$NAME" | grep -qE "$NANO_PHASE_NAME_RE"; then
  echo "ERROR: skill name '$NAME' must match ^[a-z][a-z0-9-]*$" >&2
  exit 2
fi

# Reserved: cannot reuse a core phase name.
case " $NANO_CORE_PHASES_LIST " in
  *" $NAME "*)
    echo "ERROR: '$NAME' is a core phase; choose a different skill name" >&2
    exit 2
    ;;
esac

TEMPLATE="$NANOSTACK_ROOT/examples/custom-skill-template/audit-licenses"
CONCURRENCY=""
DEPS=""
REGISTER=true

while [ $# -gt 0 ]; do
  case "$1" in
    --from)
      TEMPLATE="$2"
      shift 2
      ;;
    --concurrency)
      case "$2" in
        read|write|exclusive) CONCURRENCY="$2" ;;
        *) echo "ERROR: --concurrency must be read|write|exclusive" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --depends-on)
      if ! printf '%s' "$2" | grep -qE "$NANO_PHASE_NAME_RE"; then
        echo "ERROR: --depends-on '$2' must match ^[a-z][a-z0-9-]*$" >&2
        exit 2
      fi
      DEPS="${DEPS:+$DEPS }$2"
      shift 2
      ;;
    --register)    REGISTER=true; shift ;;
    --no-register) REGISTER=false; shift ;;
    *) echo "ERROR: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

if [ ! -d "$TEMPLATE" ]; then
  echo "ERROR: template directory '$TEMPLATE' does not exist" >&2
  exit 2
fi
if [ ! -f "$TEMPLATE/SKILL.md" ]; then
  echo "ERROR: template '$TEMPLATE' has no SKILL.md" >&2
  exit 2
fi

# Skills root inside the resolved store. Conductor's
# nano_phase_skill_path walks <store>/skills first, so a skill written
# here is picked up automatically by the same scripts that read it
# (save-artifact, resolve, conductor) regardless of cwd.
DEST_ROOT="$NANOSTACK_STORE/skills"
DEST="$DEST_ROOT/$NAME"
if [ -e "$DEST" ]; then
  echo "ERROR: $DEST already exists; remove it or pick a different name" >&2
  exit 2
fi
mkdir -p "$DEST_ROOT"
cp -R "$TEMPLATE" "$DEST"

# Substitute the template's source name with the new one wherever the
# source name appears as a literal token. The template is curated to
# only use the name in safe locations (frontmatter `name:`, code
# fences, /commands), so a global replacement is safe.
TEMPLATE_NAME=$(basename "$TEMPLATE")
if [ "$TEMPLATE_NAME" != "$NAME" ]; then
  for f in "$DEST/SKILL.md" "$DEST/agents/openai.yaml" "$DEST/README.md"; do
    [ -f "$f" ] || continue
    # Use a temp file to keep the rename atomic and avoid in-place
    # editing differences between BSD and GNU sed.
    sed "s|$TEMPLATE_NAME|$NAME|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
fi

# Optional frontmatter overrides. Both updates target lines that begin
# with `concurrency:` or `depends_on:` in the SKILL.md frontmatter.
if [ -n "$CONCURRENCY" ]; then
  sed "s|^concurrency:.*|concurrency: $CONCURRENCY|" "$DEST/SKILL.md" > "$DEST/SKILL.md.tmp" \
    && mv "$DEST/SKILL.md.tmp" "$DEST/SKILL.md"
fi
if [ -n "$DEPS" ]; then
  # Build inline list form: depends_on: [a, b, c]
  DEPS_INLINE=$(echo "$DEPS" | tr ' ' ',' | sed 's/,/, /g')
  sed "s|^depends_on:.*|depends_on: [$DEPS_INLINE]|" "$DEST/SKILL.md" > "$DEST/SKILL.md.tmp" \
    && mv "$DEST/SKILL.md.tmp" "$DEST/SKILL.md"
fi

# Registration in <store>/config.json (idempotent). Same path
# lifecycle scripts read from, so a registration here is visible to
# every consumer (save-artifact, resolve, analytics, conductor).
CONFIG="$NANOSTACK_STORE/config.json"
if [ "$REGISTER" = true ]; then
  mkdir -p "$NANOSTACK_STORE"
  if [ -f "$CONFIG" ]; then
    jq --arg n "$NAME" '.custom_phases = ((.custom_phases // []) + [$n] | unique)' \
      "$CONFIG" > "$CONFIG.tmp" \
      && mv "$CONFIG.tmp" "$CONFIG"
  else
    jq -n --arg n "$NAME" '{custom_phases: [$n]}' > "$CONFIG"
  fi
fi

echo "Created skill at $DEST"
if [ "$REGISTER" = true ]; then
  echo "Registered phase '$NAME' in $CONFIG"
fi
echo
echo "Next:"
echo "  bin/check-custom-skill.sh $DEST"
echo "  Then restart your agent so it picks up the new skill."
