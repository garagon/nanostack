#!/usr/bin/env bash
# nano-doctor.sh — Install health check for nanostack.
#
# Diagnoses the local install: dependencies, permissions, telemetry
# config, and the pre-V5 detection path. Built after PR #124 where a
# silent pre-V5 false positive hid a bug for three days. Anything this
# script checks is something that has already failed at least once.
#
# Usage:
#   nano-doctor.sh                 Human-readable report
#   nano-doctor.sh --json          Machine-readable output
#   nano-doctor.sh --offline       Skip network checks
#   nano-doctor.sh --fix           Fix mechanical issues (chmod 700, etc.)
#
# Exit codes:
#   0  all healthy
#   1  warnings only
#   2  critical issues
#
# Never prompts, never writes to stdout if --json. Errors and fix
# messages go to stderr in --json mode so the JSON stays valid.

# ─── Flags ─────────────────────────────────────────────────────────────

JSON_OUTPUT=false
OFFLINE_MODE=false
FIX_MODE=false
for arg in "$@"; do
  case "$arg" in
    --json)    JSON_OUTPUT=true ;;
    --offline) OFFLINE_MODE=true ;;
    --fix)     FIX_MODE=true ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
  esac
done

# ─── Paths ─────────────────────────────────────────────────────────────

NANO_HOME="${NANO_TEL_HOME:-$HOME/.nanostack}"
NANO_SKILL_DIR=""
for candidate in \
  "$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" \
  "$HOME/.claude/skills/nanostack"; do
  if [ -n "$candidate" ] && [ -f "$candidate/VERSION" ]; then
    NANO_SKILL_DIR="$candidate"
    break
  fi
done
# Fallback: at least report the default expected path.
NANO_SKILL_DIR="${NANO_SKILL_DIR:-$HOME/.claude/skills/nanostack}"

NANO_WORKER_URL="${NANO_WORKER_URL:-https://nanostack-telemetry.remoto.workers.dev}"

# ─── Check registry ────────────────────────────────────────────────────
# Each check appends a line to CHECK_LINES of the form:
#   <status>|<category>|<name>|<detail>
# status: pass | warn | fail

CHECK_LINES=""
FIX_LINES=""
PASS=0
WARN=0
FAIL=0

add_check() {
  local status="$1" category="$2" name="$3" detail="$4"
  CHECK_LINES="$CHECK_LINES$status|$category|$name|$detail
"
  case "$status" in
    pass) PASS=$((PASS + 1)) ;;
    warn) WARN=$((WARN + 1)) ;;
    fail) FAIL=$((FAIL + 1)) ;;
  esac
}

add_fix() {
  FIX_LINES="$FIX_LINES$1
"
}

# ─── 1. Dependencies ───────────────────────────────────────────────────

if command -v jq >/dev/null 2>&1; then
  add_check pass deps jq "$(jq --version 2>/dev/null || echo present)"
else
  add_check fail deps jq "missing — install with 'brew install jq' or 'apt install jq'"
fi

if command -v curl >/dev/null 2>&1; then
  add_check pass deps curl "$(curl --version 2>/dev/null | head -1 | awk '{print $1,$2}')"
else
  add_check warn deps curl "missing — telemetry sender cannot run without curl"
fi

_bash_major=$(bash --version 2>/dev/null | head -1 | sed -n 's/.*version \([0-9]*\).*/\1/p')
if [ -n "$_bash_major" ] && [ "$_bash_major" -ge 3 ] 2>/dev/null; then
  add_check pass deps bash "$(bash --version | head -1 | awk '{print $4}')"
else
  add_check warn deps bash "could not detect version; nanostack needs 3.2+"
fi

# ─── 2. Install integrity ──────────────────────────────────────────────

if [ -d "$NANO_SKILL_DIR" ]; then
  add_check pass install skill_dir "$NANO_SKILL_DIR"
else
  add_check fail install skill_dir "missing at $NANO_SKILL_DIR — reinstall with npx create-nanostack"
fi

if [ -f "$NANO_SKILL_DIR/VERSION" ]; then
  _ver=$(tr -d '[:space:]' < "$NANO_SKILL_DIR/VERSION")
  if [ -n "$_ver" ]; then
    add_check pass install version "$_ver"
  else
    add_check warn install version "VERSION file is empty — events will report 'unknown'"
  fi
else
  add_check warn install version "VERSION missing — events will report 'unknown'"
fi

_sender="$NANO_SKILL_DIR/bin/telemetry-log.sh"
if [ -x "$_sender" ]; then
  add_check pass install sender_executable "$_sender"
elif [ -f "$_sender" ]; then
  if $FIX_MODE; then
    if chmod +x "$_sender" 2>/dev/null; then
      add_fix "chmod +x $_sender"
      add_check pass install sender_executable "fixed — chmod +x applied"
    else
      add_check fail install sender_executable "not executable, chmod failed"
    fi
  else
    add_check warn install sender_executable "exists but not executable (run with --fix to repair)"
  fi
else
  add_check warn install sender_executable "missing — remote telemetry disabled"
fi

# ─── 3. Nanostack home ─────────────────────────────────────────────────

if [ -d "$NANO_HOME" ]; then
  add_check pass home directory "$NANO_HOME"
  # Permissions check: 700 is the expected value set by nano_telemetry_init.
  # Anything looser exposes installation_id and pending markers on shared
  # systems. chmod 600 on files is also expected; we sample user-config.json
  # and installation-id.
  if [ "$(stat -c %a "$NANO_HOME" 2>/dev/null || stat -f %p "$NANO_HOME" 2>/dev/null | tail -c 4)" = "700" ] 2>/dev/null; then
    add_check pass home permissions "700 (owner only)"
  else
    _perm=$(stat -c %a "$NANO_HOME" 2>/dev/null || stat -f %Lp "$NANO_HOME" 2>/dev/null)
    if $FIX_MODE; then
      if chmod 700 "$NANO_HOME" 2>/dev/null; then
        add_fix "chmod 700 $NANO_HOME"
        add_check pass home permissions "fixed — chmod 700 applied (was $_perm)"
      else
        add_check warn home permissions "expected 700, got $_perm; chmod failed"
      fi
    else
      add_check warn home permissions "expected 700, got $_perm (run with --fix to repair)"
    fi
  fi
else
  # Absence is fine — means you have not opted into anything yet.
  add_check pass home directory "not created yet (expected on fresh installs)"
fi

# ─── 4. Telemetry config ───────────────────────────────────────────────

_cfg="$NANO_HOME/user-config.json"
if [ -f "$_cfg" ]; then
  _tier=$(jq -r '.telemetry // "off"' "$_cfg" 2>/dev/null)
  case "$_tier" in
    off|anonymous|community)
      add_check pass telemetry tier "$_tier" ;;
    *)
      add_check warn telemetry tier "unrecognized value '$_tier' — treated as 'off'" ;;
  esac
else
  add_check pass telemetry tier "no config (tier defaults to off)"
fi

_iid="$NANO_HOME/installation-id"
if [ -f "$_iid" ]; then
  _iid_val=$(tr -d '[:space:]' < "$_iid" 2>/dev/null)
  # UUID v4 shape: 8-4-4-4-12 hex with v4 nibble and RFC 4122 variant.
  if [ "${#_iid_val}" -eq 36 ] && echo "$_iid_val" | \
     grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
    add_check pass telemetry installation_id "valid UUID v4"
  else
    add_check warn telemetry installation_id "file exists but is not a valid UUID v4"
  fi
fi

# ─── 5. Pre-V5 detection outcome ───────────────────────────────────────
# Run nano_telemetry_init under NANOSTACK_DEBUG=1 and capture the debug
# line. Restricts to a non-side-effect context: we source the helper into
# a subshell that writes to a throwaway NANO_TEL_HOME copy so the real
# home state is not mutated.

_tel_lib="$NANO_SKILL_DIR/bin/lib/telemetry.sh"
if [ -f "$_tel_lib" ]; then
  _probe=$(bash -c "
    NANO_TEL_HOME='$NANO_HOME'
    NANOSTACK_DEBUG=1
    export NANO_TEL_HOME NANOSTACK_DEBUG
    . '$_tel_lib' >/dev/null 2>&1
    # Call the branch checker directly; skip full init so no markers change.
    if nano_tel_is_pre_v5_user 2>/dev/null; then echo pre-v5; else echo fresh-or-prompted; fi
  " 2>/dev/null)

  case "$_probe" in
    pre-v5)
      if [ -f "$NANO_HOME/.telemetry-prompted" ]; then
        add_check pass detection pre_v5 "classified as pre-V5 (expected for installs from before April 2026)"
      else
        add_check warn detection pre_v5 "classified as pre-V5 but prompted-marker missing; prompt will skip on next run"
      fi ;;
    fresh-or-prompted)
      if [ -f "$NANO_HOME/.telemetry-prompted" ]; then
        add_check pass detection pre_v5 "already prompted; skip=1 on next run"
      else
        add_check pass detection pre_v5 "fresh install; prompt will fire on next /think"
      fi ;;
    *)
      add_check warn detection pre_v5 "could not source telemetry.sh for probe" ;;
  esac
else
  add_check fail detection pre_v5 "telemetry.sh missing at $_tel_lib"
fi

# ─── 6. Permission scope ───────────────────────────────────────────────
# Surface settings.json entries that grant broad filesystem deletion.
# Current nanostack installs default to narrow rm permissions
# (.nanostack/** and /tmp/**). Installs done before that change may
# still have Bash(rm:*) in their settings. Flag it as a warning with
# a concrete remediation so users can opt into narrowing.

_settings_paths=""
[ -f .claude/settings.json ]              && _settings_paths="$_settings_paths .claude/settings.json"
[ -f "$HOME/.claude/settings.json" ]      && _settings_paths="$_settings_paths $HOME/.claude/settings.json"
[ -f "$HOME/.claude/settings.local.json" ] && _settings_paths="$_settings_paths $HOME/.claude/settings.local.json"

if [ -n "$_settings_paths" ] && command -v jq >/dev/null 2>&1; then
  _broad=""
  for _s in $_settings_paths; do
    if jq -e '.permissions.allow // [] | any(. == "Bash(rm:*)")' "$_s" >/dev/null 2>&1; then
      _broad="${_broad:+$_broad, }$_s"
    fi
  done
  if [ -n "$_broad" ]; then
    add_check warn permissions rm_scope "Bash(rm:*) present in $_broad; consider narrowing to Bash(rm:.nanostack/**) and Bash(rm:/tmp/**). See SECURITY.md."
  else
    add_check pass permissions rm_scope "no broad Bash(rm:*) entries found"
  fi
else
  add_check pass permissions rm_scope "no settings.json to check"
fi

# ─── 7. Worker reachability ────────────────────────────────────────────

if $OFFLINE_MODE; then
  add_check pass network worker_reachable "skipped (--offline)"
elif ! command -v curl >/dev/null 2>&1; then
  add_check warn network worker_reachable "skipped (curl not installed)"
else
  _status=$(curl -s -o /dev/null -w '%{http_code}' \
    --max-time 5 --connect-timeout 2 \
    "$NANO_WORKER_URL/" 2>/dev/null)
  if [ "$_status" = "200" ]; then
    add_check pass network worker_reachable "$NANO_WORKER_URL ($_status)"
  else
    add_check warn network worker_reachable "$NANO_WORKER_URL returned $_status (remote telemetry will silently fail)"
  fi
fi

# ─── Output ────────────────────────────────────────────────────────────

if $JSON_OUTPUT; then
  # Emit a JSON document with per-check rows and a summary.
  _checks_json=$(printf '%s' "$CHECK_LINES" | awk -F'|' -v OFS='' '
    /^$/ { next }
    {
      gsub(/"/, "\\\"", $4)
      printf "%s{\"status\":\"%s\",\"category\":\"%s\",\"name\":\"%s\",\"detail\":\"%s\"}", (NR>1?",":""), $1, $2, $3, $4
    }
  ')
  _overall="pass"
  if [ "$FAIL" -gt 0 ]; then _overall="fail"
  elif [ "$WARN" -gt 0 ]; then _overall="warn"
  fi
  printf '{"overall":"%s","pass":%d,"warn":%d,"fail":%d,"checks":[%s]}\n' \
    "$_overall" "$PASS" "$WARN" "$FAIL" "$_checks_json"
else
  # Human-readable report.
  echo ""
  _overall="healthy"
  if [ "$FAIL" -gt 0 ]; then _overall="critical issues"
  elif [ "$WARN" -gt 0 ]; then _overall="warnings"
  fi
  echo "Nanostack install health: $_overall"
  echo "  pass: $PASS  warn: $WARN  fail: $FAIL"
  echo "============================================"
  _last_cat=""
  printf '%s' "$CHECK_LINES" | while IFS='|' read -r status category name detail; do
    [ -z "$status" ] && continue
    if [ "$category" != "$_last_cat" ]; then
      echo ""
      echo "[$category]"
      _last_cat="$category"
    fi
    case "$status" in
      pass) _icon="ok  " ;;
      warn) _icon="warn" ;;
      fail) _icon="FAIL" ;;
      *)    _icon="    " ;;
    esac
    printf '  %s  %-24s %s\n' "$_icon" "$name" "$detail"
  done
  echo ""
  if [ -n "$FIX_LINES" ]; then
    echo "Fixes applied:"
    printf '%s' "$FIX_LINES" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "  $line"
    done
    echo ""
  fi
  if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo "Everything checks out."
  elif [ "$FAIL" -gt 0 ]; then
    echo "Fix the items marked FAIL first. Re-run with --fix for mechanical repairs."
  else
    echo "Re-run with --fix to repair the items that allow auto-fix."
  fi
fi

# ─── Exit code ─────────────────────────────────────────────────────────

if [ "$FAIL" -gt 0 ]; then
  exit 2
elif [ "$WARN" -gt 0 ]; then
  exit 1
fi
exit 0
