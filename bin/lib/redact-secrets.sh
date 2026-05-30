#!/usr/bin/env bash
# redact-secrets.sh — mask inline secrets in a command string.
#
# Source this file, then call: redact_secrets "<command>"  (prints the masked
# form). Used by the guard audit log and deny output (check-dangerous.sh) and by
# the sprint phase gate audit write (phase-gate.sh) so a command carrying a
# token, password, bearer header, or a secret-looking env assignment does not
# leave the secret in a log file or the agent transcript.
#
# It masks: Authorization: Bearer headers; token / password / api-key / secret /
# access-key values given with = : or as a --flag (quoted or bare, including
# multi-word quoted values); and UPPERCASE secret env assignments
# (TOKEN=, API_KEY=, FOO_SECRET=, ...). Keyword and header matches are
# case-insensitive (written as explicit letter classes so this works on both
# GNU and BSD sed). The value becomes *** and the command shape stays readable.
# Best effort: it cannot recognize every secret format.

# shellcheck disable=SC2120
redact_secrets() {
  # Case-insensitive keyword alternation (covers lower, Mixed, and UPPER).
  local _kw='[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Kk][Ee][Yy]|[Aa][Uu][Tt][Hh][_-]?[Tt][Oo][Kk][Ee][Nn]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee][_-]?[Kk][Ee][Yy]|[_-][Kk][Ee][Yy]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll][Ss]?'
  local _bearer='[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+'
  # A trailing [A-Za-z0-9_-]* after the keyword catches suffixed names such as
  # SECRET_KEY= or --secret-key (the keyword need not be the whole identifier).
  # The optional "? after the keyword also matches a JSON-style quoted key such
  # as {"api_key":"sk..."} before the : separator.
  printf '%s' "${1:-}" | sed -E \
    -e "s/($_bearer)[A-Za-z0-9._~+/=-]+/\1***/g" \
    -e "s/(($_kw)[A-Za-z0-9_-]*\"?[[:space:]]*[=:][[:space:]]*)('[^']*'|\"[^\"]*\")/\1***/g" \
    -e "s/(--?($_kw)[A-Za-z0-9_-]*[[:space:]]+)('[^']*'|\"[^\"]*\")/\1***/g" \
    -e "s/(($_kw)[A-Za-z0-9_-]*\"?[[:space:]]*[=:][[:space:]]*)(['\"]?)[^[:space:]'\"{},;|&]+/\1\3***/g" \
    -e "s/(--?($_kw)[A-Za-z0-9_-]*[[:space:]]+)(['\"]?)[^[:space:]'\"{},;|&]+/\1\3***/g"
}
