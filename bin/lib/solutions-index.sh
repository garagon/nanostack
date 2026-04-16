#!/usr/bin/env bash
# solutions-index.sh — Build and serve a single JSON index of all solution
# frontmatters. Replaces the per-file sed/grep frontmatter parsing that
# dominates find-solution.sh, doctor.sh and graduate.sh on repos with many
# solutions.
#
# Source this file (after lib/store-path.sh and lib/cache.sh).
#
# Public function:
#   nano_solutions_index   Echo a JSON array. Each element:
#       {
#         "path": "...md",
#         "type": "bug" | "pattern" | "decision" | "...",
#         "title": "...",
#         "severity": "...",
#         "tags": ["..."],
#         "files": ["..."],
#         "applied_count": N,
#         "validated": true|false,
#         "graduated": true|false,
#         "date": "YYYY-MM-DD",
#         "last_validated": "...",
#         "confidence": N
#       }
#
# Cache lives at "$NANOSTACK_STORE/.cache/solutions-index.json" and is
# regenerated when the solutions directory mtime is newer. NANOSTACK_NO_CACHE=1
# bypasses the cache for debugging.

# Parse one solution's frontmatter into a single-line JSON object.
# Uses awk to walk the --- ... --- block. Recognizes:
#   key: scalar          -> string
#   key: true|false      -> bool
#   key: 0..9+           -> number
#   key: [a, b, c]       -> array of strings
# Any other shape falls through as a string.
_nano_parse_frontmatter() {
  local file="$1"
  awk -v file="$file" '
    function jescape(s,    out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\")      out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\t") out = out "\\t"
        else if (c == "\n") out = out "\\n"
        else if (c == "\r") out = out "\\r"
        else                out = out c
      }
      return out
    }
    function emit_value(v,    n, i, item, items) {
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v == "true" || v == "false")            return v
      if (v ~ /^-?[0-9]+$/)                       return v
      if (v ~ /^\[.*\]$/) {
        # array: strip [], split by comma, strip quotes/space per item
        sub(/^\[/, "", v); sub(/\]$/, "", v)
        if (v == "") return "[]"
        n = split(v, items, ",")
        out = "["
        for (i = 1; i <= n; i++) {
          item = items[i]
          gsub(/^[ \t"'\'']+|[ \t"'\'']+$/, "", item)
          if (i > 1) out = out ","
          out = out "\"" jescape(item) "\""
        }
        return out "]"
      }
      # plain string
      sub(/^"/, "", v); sub(/"$/, "", v)
      return "\"" jescape(v) "\""
    }
    BEGIN { in_fm = 0; first = 1; printf "{\"path\":\"%s\"", file }
    /^---[ \t]*$/ {
      if (in_fm == 0) { in_fm = 1; next }
      else            { in_fm = 0; printf "}\n"; exit }
    }
    in_fm == 1 {
      # parse "key: value"
      pos = index($0, ":")
      if (pos < 2) next
      key = substr($0, 1, pos - 1)
      val = substr($0, pos + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      printf ",\"%s\":%s", jescape(key), emit_value(val)
    }
    END { if (in_fm == 1) printf "}\n" }
  ' "$file"
}

# Build the cache from scratch.
_nano_build_solutions_index() {
  local sol_dir="$1" cache_file="$2"
  local tmp="${cache_file}.tmp.$$"
  mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true

  # Collect each parsed object on its own line, then wrap in an array.
  # Files with broken frontmatter produce an object with only {path: ...},
  # which is harmless: queries on missing fields skip them.
  {
    find "$sol_dir" -name '*.md' -type f 2>/dev/null | while read -r f; do
      _nano_parse_frontmatter "$f"
    done
  } | jq -s '.' > "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$cache_file"
}

# Public entry point: print the JSON index to stdout.
nano_solutions_index() {
  local sol_dir="${1:-$NANOSTACK_STORE/know-how/solutions}"
  [ -d "$sol_dir" ] || { echo "[]"; return 0; }

  local cache_file=""
  if declare -F nano_cache_dir >/dev/null 2>&1; then
    cache_file="$(nano_cache_dir)/solutions-index.json"
  fi

  if [ -n "$cache_file" ] && nano_cache_fresh "$cache_file" 60 "$sol_dir" 2>/dev/null; then
    cat "$cache_file"
    return 0
  fi

  if [ -n "$cache_file" ]; then
    _nano_build_solutions_index "$sol_dir" "$cache_file" && cat "$cache_file"
  else
    # No cache infrastructure available — build into a temp file.
    local tmp; tmp=$(mktemp)
    _nano_build_solutions_index "$sol_dir" "$tmp" && cat "$tmp"
    rm -f "$tmp"
  fi
}
