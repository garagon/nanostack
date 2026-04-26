#!/usr/bin/env bash
# audit.sh — license-audit skill helper.
#
# Walks direct dependencies of the project in cwd and classifies each
# declared license into one of four families: permissive, weak
# copyleft, strong copyleft, unknown. Emits a JSON object with a
# `counts` map and a `flagged` list of strong-copyleft hits.
#
# Stack detection is automatic: the helper looks for package.json,
# requirements.txt, pyproject.toml, or go.mod in the current directory.
# Pass an optional positional argument (node|python|go) to force a
# specific stack when more than one manifest is present.
#
# This is a release-hygiene check, not a production license scanner.
# Direct dependencies only; transitive deps are out of scope. For
# Node, license metadata is read from each module's package.json
# under node_modules/ when available; otherwise the dep is recorded
# as unknown. Python and Go manifests do not declare license metadata,
# so deps from those stacks always classify as unknown unless the
# user runs a deeper auditor.
#
# Exit always 0; the artifact's summary.status carries OK/WARN/BLOCKED
# (computed from the counts and flagged list by the calling skill).
set -eu

# ─── Stack detection ─────────────────────────────────────────
detect_stack() {
  if [ -f package.json ]; then printf 'node'; return; fi
  if [ -f pyproject.toml ] || [ -f requirements.txt ]; then printf 'python'; return; fi
  if [ -f go.mod ]; then printf 'go'; return; fi
  printf 'none'
}

STACK="${1:-$(detect_stack)}"

# ─── License family classifier ───────────────────────────────
classify() {
  local lic="$1"
  lic=$(printf '%s' "$lic" | tr '[:lower:]' '[:upper:]' | tr -d ' "')
  case "$lic" in
    MIT|BSD*|APACHE*|ISC|0BSD|UNLICENSE|CC0*) printf 'permissive' ;;
    LGPL*|MPL*|EPL*)                          printf 'weak_copyleft' ;;
    GPL*|AGPL*)                               printf 'strong_copyleft' ;;
    *)                                        printf 'unknown' ;;
  esac
}

# ─── Per-stack scanners ──────────────────────────────────────
scan_node() {
  [ -f package.json ] || return 0
  jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' package.json 2>/dev/null | while read -r dep; do
    [ -z "$dep" ] && continue
    local mod_pkg="node_modules/$dep/package.json"
    local lic="unknown"
    if [ -f "$mod_pkg" ]; then
      lic=$(jq -r '
        .license // (
          .licenses // []
          | if type == "array" and length > 0 then (.[0].type // "unknown")
            else "unknown" end
        )
      ' "$mod_pkg" 2>/dev/null)
      [ -z "$lic" ] || [ "$lic" = "null" ] && lic="unknown"
    fi
    printf '%s\t%s\n' "$dep" "$lic"
  done
}

scan_python() {
  if [ -f pyproject.toml ]; then
    grep -E '^[a-zA-Z0-9_-]+[ ]*=|^"[^"]+' pyproject.toml 2>/dev/null | head -50 | \
      awk -F'[="]' '{print $1}' | sed 's/[[:space:]]//g' | while read -r dep; do
      [ -z "$dep" ] && continue
      printf '%s\tunknown\n' "$dep"
    done
  elif [ -f requirements.txt ]; then
    grep -vE '^#|^$' requirements.txt 2>/dev/null | while read -r line; do
      local dep="${line%%[<>=~!]*}"
      dep=$(printf '%s' "$dep" | tr -d '[:space:]')
      [ -z "$dep" ] && continue
      printf '%s\tunknown\n' "$dep"
    done
  fi
}

scan_go() {
  [ -f go.mod ] || return 0
  grep -E '^[[:space:]]+[a-zA-Z0-9._/-]+' go.mod 2>/dev/null | awk '{print $1}' | while read -r dep; do
    [ -z "$dep" ] && continue
    printf '%s\tunknown\n' "$dep"
  done
}

# ─── Run and aggregate ───────────────────────────────────────
case "$STACK" in
  node)   RAW=$(scan_node) ;;
  python) RAW=$(scan_python) ;;
  go)     RAW=$(scan_go) ;;
  none)
    # No supported manifest in cwd. Emit an empty result rather than
    # erroring; the calling skill marks status=WARN with a clear
    # next_action ("no supported manifest found").
    RAW=""
    ;;
  *) echo "unknown stack: $STACK" >&2; exit 2 ;;
esac

PERMISSIVE=0
WEAK=0
STRONG=0
UNKNOWN=0
FLAGGED_LIST=""

while IFS=$'\t' read -r name license; do
  [ -z "$name" ] && continue
  family=$(classify "$license")
  case "$family" in
    permissive)    PERMISSIVE=$((PERMISSIVE + 1)) ;;
    weak_copyleft) WEAK=$((WEAK + 1)) ;;
    strong_copyleft)
      STRONG=$((STRONG + 1))
      FLAGGED_LIST="${FLAGGED_LIST}${name}|${license}
"
      ;;
    unknown) UNKNOWN=$((UNKNOWN + 1)) ;;
  esac
done <<< "$RAW"

FLAGGED="[]"
if [ -n "$FLAGGED_LIST" ]; then
  FLAGGED=$(printf '%s' "$FLAGGED_LIST" | awk -F'|' 'NF==2 {printf "{\"name\":\"%s\",\"license\":\"%s\"}\n",$1,$2}' | jq -s '.')
fi

TOTAL=$((PERMISSIVE + WEAK + STRONG + UNKNOWN))

jq -n \
  --arg stack "$STACK" \
  --argjson total "$TOTAL" \
  --argjson permissive "$PERMISSIVE" \
  --argjson weak "$WEAK" \
  --argjson strong "$STRONG" \
  --argjson unknown "$UNKNOWN" \
  --argjson flagged "$FLAGGED" \
  '{
    stack: $stack,
    counts: {
      total: $total,
      permissive: $permissive,
      weak_copyleft: $weak,
      strong_copyleft: $strong,
      unknown: $unknown
    },
    flagged: $flagged
  }'
