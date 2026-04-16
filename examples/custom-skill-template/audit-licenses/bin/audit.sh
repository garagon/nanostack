#!/usr/bin/env bash
# audit.sh — Dependency license audit, example custom skill helper.
#
# Not a production license scanner. Walks direct dependencies only (no
# transitive resolution) and maps each declared license to one of four
# families. The goal is to show how a custom nanostack skill wires up a
# bash helper with portable tooling and returns structured output.
#
# Usage: audit.sh <node|python|go>
# Output: JSON on stdout with counts + flagged list.
set -eu

STACK="${1:-}"
[ -z "$STACK" ] && { echo "Usage: audit.sh <node|python|go>" >&2; exit 2; }

# ─── License family classifier ───────────────────────────────
classify() {
  local lic="$1"
  # Normalize: uppercase, strip whitespace and quotes
  lic=$(printf '%s' "$lic" | tr '[:lower:]' '[:upper:]' | tr -d ' "')
  case "$lic" in
    MIT|BSD*|APACHE*|ISC|0BSD|UNLICENSE|CC0*)              echo "permissive" ;;
    LGPL*|MPL*|EPL*)                                       echo "weak_copyleft" ;;
    GPL*|AGPL*)                                            echo "strong_copyleft" ;;
    *)                                                     echo "unknown" ;;
  esac
}

# ─── Stack-specific scanners ─────────────────────────────────
scan_node() {
  [ -f package.json ] || { echo "no package.json" >&2; return 1; }
  # Read direct deps + devDeps and their declared license from each module's
  # own package.json under node_modules. Falls back to "unknown" when the
  # module is not installed.
  jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' package.json 2>/dev/null | while read -r dep; do
    [ -z "$dep" ] && continue
    local mod_pkg="node_modules/$dep/package.json"
    local lic="unknown"
    if [ -f "$mod_pkg" ]; then
      lic=$(jq -r '.license // (.licenses // [] | if type == "array" then .[0].type // "unknown" else . end)' "$mod_pkg" 2>/dev/null)
      [ -z "$lic" ] && lic="unknown"
    fi
    printf '%s\t%s\n' "$dep" "$lic"
  done
}

scan_python() {
  if [ -f pyproject.toml ]; then
    # Direct deps under [project.dependencies] or [tool.poetry.dependencies]
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
  else
    echo "no requirements.txt or pyproject.toml" >&2
    return 1
  fi
}

scan_go() {
  [ -f go.mod ] || { echo "no go.mod" >&2; return 1; }
  grep -E '^[[:space:]]+[a-zA-Z0-9._/-]+' go.mod | awk '{print $1}' | while read -r dep; do
    [ -z "$dep" ] && continue
    printf '%s\tunknown\n' "$dep"
  done
}

# ─── Run and aggregate ───────────────────────────────────────
case "$STACK" in
  node)   RAW=$(scan_node) ;;
  python) RAW=$(scan_python) ;;
  go)     RAW=$(scan_go) ;;
  *)      echo "unknown stack: $STACK" >&2; exit 2 ;;
esac

PERMISSIVE=0
WEAK=0
STRONG=0
UNKNOWN=0
FLAGGED="[]"
FLAGGED_LIST=""

while IFS=$'\t' read -r name license; do
  [ -z "$name" ] && continue
  family=$(classify "$license")
  case "$family" in
    permissive)      PERMISSIVE=$((PERMISSIVE + 1)) ;;
    weak_copyleft)   WEAK=$((WEAK + 1)) ;;
    strong_copyleft)
      STRONG=$((STRONG + 1))
      FLAGGED_LIST="${FLAGGED_LIST}${name}|${license}
"
      ;;
    unknown)         UNKNOWN=$((UNKNOWN + 1)) ;;
  esac
done <<< "$RAW"

# Build the flagged JSON array safely with jq
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
