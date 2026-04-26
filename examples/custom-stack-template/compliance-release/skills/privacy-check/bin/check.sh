#!/usr/bin/env bash
# check.sh — privacy-check skill helper.
#
# Release-hygiene scan. Reads files from cwd and surfaces three
# classes of signal:
#   1. personal_data — code mentions email/name/phone/address/payment/
#      token/api_key/file upload in source files under common
#      locations (src/, app/, pages/, server/, api/).
#   2. telemetry    — code imports analytics/tracking/telemetry
#      libraries (analytics, tracking, telemetry, segment, posthog,
#      ga, mixpanel, sentry).
#   3. env_template — env templates (.env.example, .env.sample,
#      .env.template) reference keys that hint at collection
#      (anything containing email, phone, payment, secret, token).
#
# Then checks whether a privacy note exists: PRIVACY.md at repo root,
# or a "Privacy" / "Data" / "Privacidad" H2 in README.md, or
# TELEMETRY.md when the only signal class is telemetry.
#
# This is NOT a legal review. It is a deterministic release-hygiene
# check that catches the easy misses. It never reads .env, .env.local,
# .env.production, or credential JSON (the bash guard already blocks
# those at the host layer).
#
# Output: JSON object with `signals` and `missing`. The calling skill
# maps these to summary.status:
#   OK     — no signals, or signals + privacy note present.
#   WARN   — signals present and privacy note missing.
#   BLOCKED — reserved for clearly unsafe patterns; this helper does
#             not emit BLOCKED on its own (the composer in
#             /release-readiness escalates if needed).
set -eu

# Source roots to scan. Bounded to common app-code locations so the
# scanner doesn't walk node_modules / .venv / vendor.
SOURCE_ROOTS="src app pages server api lib"

# Personal-data field markers. Match as whole-word tokens to avoid
# false positives on identifiers that happen to contain "email" as a
# substring (e.g. "emailing-list-name"). The `name` token is a known
# false-positive magnet (it appears in lots of code unrelated to user
# collection); we keep it because the SKILL contract says we cover
# it, and the user triages the per-file evidence list.
PERSONAL_RE='\b(email|name|phone|address|payment|credit_?card|ssn|api[_-]?key|access[_-]?token|file[_-]?upload)\b'

# Telemetry libraries. These are import-statement substrings;
# language-agnostic so the same pattern catches `from sentry`,
# `require('posthog')`, `import segment from`, etc. `ga` (Google
# Analytics) is short and noisy, but the SKILL contract names it
# explicitly; the user triages the per-file evidence list.
TELEMETRY_RE='\b(analytics|tracking|telemetry|segment|posthog|ga|mixpanel|sentry)\b'

# Env-template indicators that hint at collection. Matches against
# variable names like EMAIL_API_KEY or USER_PHONE_NUMBER.
ENV_HINT_RE='(EMAIL|PHONE|PAYMENT|SECRET|TOKEN|API[_-]?KEY)'

scan_personal_data() {
  for root in $SOURCE_ROOTS; do
    [ -d "$root" ] || continue
    grep -rEn "$PERSONAL_RE" "$root" 2>/dev/null | head -20 | while IFS=: read -r file line evidence; do
      [ -z "$file" ] && continue
      # Emit one signal per UNIQUE matching token in the line. The
      # earlier `head -1` form silently dropped the second token when
      # a single line collected both, e.g. `{ email: ..., name: ... }`
      # would only report email. Users expect both fields to surface.
      printf '%s' "$evidence" | grep -oE "$PERSONAL_RE" | sort -u | while read -r token; do
        [ -z "$token" ] && continue
        printf 'personal_data\t%s\t%s\n' "$file" "$token"
      done
    done
  done
}

scan_telemetry() {
  for root in $SOURCE_ROOTS; do
    [ -d "$root" ] || continue
    grep -rEn "$TELEMETRY_RE" "$root" 2>/dev/null | head -20 | while IFS=: read -r file line evidence; do
      [ -z "$file" ] && continue
      # Same fix: emit one signal per unique library reference in the
      # line so `import { posthog } from "sentry"` reports both.
      printf '%s' "$evidence" | grep -oiE "$TELEMETRY_RE" | tr '[:upper:]' '[:lower:]' | sort -u | while read -r token; do
        [ -z "$token" ] && continue
        printf 'telemetry\t%s\t%s\n' "$file" "$token"
      done
    done
  done
}

scan_env_templates() {
  for tmpl in .env.example .env.sample .env.template; do
    [ -f "$tmpl" ] || continue
    grep -nE "$ENV_HINT_RE" "$tmpl" 2>/dev/null | head -10 | while IFS=: read -r line evidence; do
      var=$(printf '%s' "$evidence" | grep -oE '^[A-Z_][A-Z0-9_]*' | head -1)
      [ -z "$var" ] && var="(template-key)"
      printf 'env_template\t%s\t%s\n' "$tmpl" "$var"
    done
  done
}

has_privacy_note() {
  [ -f PRIVACY.md ] && return 0
  if [ -f README.md ]; then
    if grep -qiE '^##[[:space:]]+(Privacy|Privacidad|Data[[:space:]]+(handling|collection))' README.md; then
      return 0
    fi
  fi
  return 1
}

has_telemetry_doc() {
  [ -f TELEMETRY.md ]
}

# ─── Run scans ─────────────────────────────────────────────
RAW=""
RAW="${RAW}$(scan_personal_data)
"
RAW="${RAW}$(scan_telemetry)
"
RAW="${RAW}$(scan_env_templates)
"

# Build the signals JSON array. Use jq -s to merge per-line objects.
SIGNALS="[]"
TELEMETRY_ONLY=true
PERSONAL_HIT=false
TELEMETRY_HIT=false
ENV_HIT=false

if [ -n "$(printf '%s' "$RAW" | tr -d '[:space:]')" ]; then
  SIGNALS=$(printf '%s\n' "$RAW" | awk -F'\t' '
    NF == 3 { printf "{\"kind\":\"%s\",\"file\":\"%s\",\"evidence\":\"%s\"}\n", $1, $2, $3 }
  ' | jq -s '.')
  PERSONAL_HIT=$(echo "$SIGNALS" | jq -r 'any(.kind == "personal_data")')
  TELEMETRY_HIT=$(echo "$SIGNALS" | jq -r 'any(.kind == "telemetry")')
  ENV_HIT=$(echo "$SIGNALS" | jq -r 'any(.kind == "env_template")')
fi

# Determine "missing" docs.
MISSING="[]"
ms=""
# Telemetry-only case is satisfied by TELEMETRY.md OR a privacy note.
if [ "$TELEMETRY_HIT" = "true" ] && [ "$PERSONAL_HIT" != "true" ] && [ "$ENV_HIT" != "true" ]; then
  if ! has_privacy_note && ! has_telemetry_doc; then
    ms="${ms}privacy_note "
  fi
elif [ "$PERSONAL_HIT" = "true" ] || [ "$ENV_HIT" = "true" ]; then
  if ! has_privacy_note; then
    ms="${ms}privacy_note "
  fi
fi
if [ -n "$ms" ]; then
  MISSING=$(printf '%s' "$ms" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s '.')
fi

jq -n \
  --argjson signals "$SIGNALS" \
  --argjson missing "$MISSING" \
  '{
    signals: $signals,
    missing: $missing
  }'
