#!/usr/bin/env bash
# smoke.sh — privacy-check runtime sanity check.
#
# Sets up tmp projects and asserts the scanner behavior:
#   1. clean project (no signals, no missing docs)
#   2. email collection in src/, no PRIVACY.md, no Privacy section
#      in README -> personal_data signal + missing privacy_note
#   3. same as 2 but PRIVACY.md present -> signal stays, missing empty
#   4. README.md has "## Privacy" H2 -> satisfies the privacy note
#   5. telemetry-only hit + TELEMETRY.md present -> signal stays,
#      no missing entry (TELEMETRY.md is the documented surface)
#   6. .env.example with EMAIL_API_KEY -> env_template signal
set -eu

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$SKILL_DIR/bin/check.sh"

if [ ! -x "$CHECK" ]; then
  echo "FAIL: $CHECK is not executable" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required for the smoke check" >&2
  exit 1
fi

tmp=$(mktemp -d /tmp/privacy-check-smoke.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
fail=0

# ─── Case 1: clean project ──────────────────────────────────
mkdir -p "$tmp/clean/src"
echo 'export const ok = true;' > "$tmp/clean/src/index.js"
out=$( cd "$tmp/clean" && "$CHECK" 2>&1 )
if echo "$out" | jq -e '(.signals | length) == 0 and (.missing | length) == 0' >/dev/null 2>&1; then
  echo "  ok    clean project: no signals, no missing"
else
  echo "FAIL: clean case wrong"; echo "$out"; fail=1
fi

# ─── Case 2: email collection, no privacy note ──────────────
mkdir -p "$tmp/leak/src"
cat > "$tmp/leak/src/signup.js" <<'JS'
const form = { email: input.email, name: input.name };
JS
out=$( cd "$tmp/leak" && "$CHECK" 2>&1 )
if echo "$out" | jq -e '
  (.signals | any(.kind == "personal_data"))
  and (.missing | index("privacy_note") != null)
' >/dev/null 2>&1; then
  echo "  ok    email collection without privacy note flags personal_data + missing"
else
  echo "FAIL: leak case wrong"; echo "$out"; fail=1
fi

# ─── Case 3: same with PRIVACY.md present ───────────────────
mkdir -p "$tmp/with-privacy-md/src"
cp "$tmp/leak/src/signup.js" "$tmp/with-privacy-md/src/signup.js"
echo "# Privacy" > "$tmp/with-privacy-md/PRIVACY.md"
out=$( cd "$tmp/with-privacy-md" && "$CHECK" 2>&1 )
if echo "$out" | jq -e '
  (.signals | any(.kind == "personal_data"))
  and (.missing | length) == 0
' >/dev/null 2>&1; then
  echo "  ok    PRIVACY.md satisfies the privacy_note requirement"
else
  echo "FAIL: PRIVACY.md case wrong"; echo "$out"; fail=1
fi

# ─── Case 4: README "## Privacy" section satisfies the note ─
mkdir -p "$tmp/with-readme-privacy/src"
cp "$tmp/leak/src/signup.js" "$tmp/with-readme-privacy/src/signup.js"
cat > "$tmp/with-readme-privacy/README.md" <<'MD'
# App
## Privacy
We collect email for sign-in only.
MD
out=$( cd "$tmp/with-readme-privacy" && "$CHECK" 2>&1 )
if echo "$out" | jq -e '(.missing | length) == 0' >/dev/null 2>&1; then
  echo "  ok    README '## Privacy' H2 satisfies the privacy note"
else
  echo "FAIL: README privacy case wrong"; echo "$out"; fail=1
fi

# ─── Case 5: telemetry-only with TELEMETRY.md ───────────────
mkdir -p "$tmp/telemetry-doc/src"
cat > "$tmp/telemetry-doc/src/track.js" <<'JS'
import sentry from "sentry";
sentry.init();
JS
echo "# Telemetry" > "$tmp/telemetry-doc/TELEMETRY.md"
out=$( cd "$tmp/telemetry-doc" && "$CHECK" 2>&1 )
if echo "$out" | jq -e '
  (.signals | any(.kind == "telemetry"))
  and (.signals | any(.kind == "personal_data") | not)
  and (.missing | length) == 0
' >/dev/null 2>&1; then
  echo "  ok    telemetry-only with TELEMETRY.md does not trigger missing privacy_note"
else
  echo "FAIL: telemetry-doc case wrong"; echo "$out"; fail=1
fi

# ─── Case 6: env template hint ──────────────────────────────
mkdir -p "$tmp/env-tmpl"
cat > "$tmp/env-tmpl/.env.example" <<'ENV'
EMAIL_API_KEY=sk_test_replace_me
APP_NAME=demo
ENV
out=$( cd "$tmp/env-tmpl" && "$CHECK" 2>&1 )
if echo "$out" | jq -e '
  (.signals | any(.kind == "env_template" and (.evidence | startswith("EMAIL"))))
' >/dev/null 2>&1; then
  echo "  ok    .env.example with EMAIL_API_KEY flags env_template"
else
  echo "FAIL: env_template case wrong"; echo "$out"; fail=1
fi

# ─── Case 7: name-only collection ──────────────────────────
# Spec contract names `name` as a personal-data field. A signup form
# that only collects name must trigger personal_data even when no
# email field is present.
mkdir -p "$tmp/name-only/src"
cat > "$tmp/name-only/src/profile.js" <<'JS'
const profile = { name: req.body.name };
JS
out=$( cd "$tmp/name-only" && "$CHECK" 2>&1 )
if echo "$out" | jq -e '
  (.signals | any(.kind == "personal_data" and (.evidence == "name")))
' >/dev/null 2>&1; then
  echo "  ok    name-only collection triggers personal_data"
else
  echo "FAIL: name-only case wrong"; echo "$out"; fail=1
fi

# ─── Case 8: telemetry library `ga` ─────────────────────────
# Spec contract names `ga` (Google Analytics) as a telemetry library.
# A short token is noisy but the SKILL claims coverage; the smoke
# locks the claim against quiet drift.
mkdir -p "$tmp/ga/src"
cat > "$tmp/ga/src/track.js" <<'JS'
import ga from 'react-ga';
ga('send', 'pageview');
JS
out=$( cd "$tmp/ga" && "$CHECK" 2>&1 )
if echo "$out" | jq -e '
  (.signals | any(.kind == "telemetry" and (.evidence == "ga")))
' >/dev/null 2>&1; then
  echo "  ok    ga import triggers telemetry signal"
else
  echo "FAIL: ga case wrong"; echo "$out"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "OK: privacy-check smoke passed (8 cases)"
fi
exit $fail
