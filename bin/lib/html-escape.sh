#!/usr/bin/env bash
# html-escape.sh — Shared HTML escape primitives for the visual artifact
# layer. Used by bin/render-artifact.sh. Centralizing the escape rules
# here makes the security contract testable: ci/check-visual-artifact-
# templates.sh greps for direct printf of JSON values and fails if the
# escape helpers are bypassed.
#
# Public functions (stdin -> stdout):
#   nano_html_escape   text content. & < > " ' -> entities. Preserves newlines.
#   nano_attr_escape   attribute content. Same set; stricter quoting.
#   nano_json_string   string -> JSON-encoded literal (without surrounding quotes).
#                       Used by the manifest writer when piping shell
#                       strings into JSON without a jq round-trip.

if [ "${_NANO_HTML_ESCAPE_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_NANO_HTML_ESCAPE_LOADED=1

# Escape & < > " ' via awk. Replaces ampersand FIRST so later
# replacements do not double-encode the entity prefix. Reads stdin and
# writes to stdout. Newlines pass through untouched.
nano_html_escape() {
  awk '
    BEGIN { OFS = "" }
    {
      gsub(/&/, "\\&amp;")
      gsub(/</, "\\&lt;")
      gsub(/>/, "\\&gt;")
      gsub(/"/, "\\&quot;")
      gsub(/\047/, "\\&#39;")
      print
    }
  '
}

# Attribute content uses the same character set. Kept as a separate
# function so future hardening (for example, encoding the equals sign
# or backtick inside attribute context) lands in one place. Reads
# stdin and writes to stdout.
nano_attr_escape() {
  awk '
    BEGIN { OFS = "" }
    {
      gsub(/&/, "\\&amp;")
      gsub(/</, "\\&lt;")
      gsub(/>/, "\\&gt;")
      gsub(/"/, "\\&quot;")
      gsub(/\047/, "\\&#39;")
      print
    }
  '
}

# JSON-string escape. We delegate to jq when available because jq
# already implements the full RFC 8259 escape set (control characters,
# \uXXXX for non-ASCII). The output includes surrounding double
# quotes; callers strip them with `${var:1:-1}` when embedding inside
# a larger jq filter, or use the quoted form for raw concatenation.
nano_json_string() {
  if command -v jq >/dev/null 2>&1; then
    jq -Rs '.'
  else
    # Minimal fallback. Escapes the characters that break JSON strings.
    # Loses control-character handling beyond newline; that is
    # acceptable because the visual layer pipes everything through jq
    # when jq is on PATH, which is a Nanostack requirement enforced
    # elsewhere.
    awk '
      BEGIN { ORS = ""; printf "\"" }
      {
        s = $0
        gsub(/\\/, "\\\\", s)
        gsub(/"/, "\\\"", s)
        gsub(/\t/, "\\t", s)
        printf "%s", s
        printf "\\n"
      }
      END { printf "\"\n" }
    '
  fi
}
