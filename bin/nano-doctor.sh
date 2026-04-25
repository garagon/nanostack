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
#   <status>\t<category>\t<name>\t<detail>
# Uses a tab separator instead of `|` so detail strings that include the
# pipe character (e.g. "Write|Edit|MultiEdit", "curl | sh") survive the
# round-trip into the JSON output without being truncated. Round 4
# audit caught this on a settings file with no hooks: the JSON detail
# ended at "Add the Write" because awk -F'|' split on the first |.
# status: pass | warn | fail

_NANO_DOCTOR_SEP=$'\t'
CHECK_LINES=""
FIX_LINES=""
PASS=0
WARN=0
FAIL=0

add_check() {
  local status="$1" category="$2" name="$3" detail="$4"
  CHECK_LINES="$CHECK_LINES$status$_NANO_DOCTOR_SEP$category$_NANO_DOCTOR_SEP$name$_NANO_DOCTOR_SEP$detail
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
# Enumerate settings.json files and report each broad entry. The earlier
# version of this check only looked at Bash(rm:*). Round 3 audit pointed
# out that Write(*), Edit(*), and allowlisted binaries like find and
# curl are equally part of the permission surface. The doctor now
# surfaces each one so a user who thinks "I migrated rm" sees the full
# picture.
#
# A broad entry is not automatically a problem: Write(*)/Edit(*) are
# expected on coding-agent setups, and the check-write.sh hook covers
# them. The report cross-references the hook presence so the status
# reads honestly.

_settings_paths=""
[ -f .claude/settings.json ]               && _settings_paths="$_settings_paths .claude/settings.json"
[ -f "$HOME/.claude/settings.json" ]       && _settings_paths="$_settings_paths $HOME/.claude/settings.json"
[ -f "$HOME/.claude/settings.local.json" ] && _settings_paths="$_settings_paths $HOME/.claude/settings.local.json"

_any_has() {
  # _any_has <perm> → print comma-separated settings files that list it
  local perm="$1" hits=""
  for _s in $_settings_paths; do
    if jq -e --arg p "$perm" '.permissions.allow // [] | any(. == $p)' "$_s" >/dev/null 2>&1; then
      hits="${hits:+$hits, }$_s"
    fi
  done
  printf '%s' "$hits"
}

_has_hook() {
  # _has_hook <matcher-regex> <command-substring> → 0 if any settings
  # file declares a PreToolUse hook whose matcher matches and whose
  # command contains the substring; 1 otherwise.
  local matcher="$1" needle="$2"
  for _s in $_settings_paths; do
    if jq -e --arg m "$matcher" --arg n "$needle" '
      (.hooks.PreToolUse // [])
      | any(
          (.matcher // "" | test($m))
          and ((.hooks // []) | any((.command // "") | contains($n)))
        )
    ' "$_s" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

if [ -z "$_settings_paths" ] || ! command -v jq >/dev/null 2>&1; then
  add_check pass permissions broad_perms "no settings.json to check"
  add_check pass permissions bash_guard  "no settings.json to check"
  add_check pass permissions write_guard "no settings.json to check"
else
  _bash_hook_ok=1; _has_hook 'Bash' 'check-dangerous.sh' && _bash_hook_ok=0
  _write_hook_ok=1; _has_hook 'Write|Edit' 'check-write.sh' && _write_hook_ok=0

  # Broad perm report: each entry is informational if it is backed by
  # the right hook, warn if not. Bash(rm:*) keeps its own row because
  # it is the one we actively encourage users to narrow (per SECURITY.md).
  _rm_hits=$(_any_has 'Bash(rm:*)')
  if [ -n "$_rm_hits" ]; then
    if [ "$_bash_hook_ok" -eq 0 ]; then
      add_check warn permissions rm_scope "Bash(rm:*) present in $_rm_hits. Guard hook is wired so rm -rf ./ is still blocked, but new installs default to Bash(rm:.nanostack/**) + Bash(rm:/tmp/**). See SECURITY.md."
    else
      add_check warn permissions rm_scope "Bash(rm:*) present in $_rm_hits AND no Bash guard hook wired. That is the unprotected surface the guard is supposed to cover. See SECURITY.md 'Manual wire-up for existing installs'."
    fi
  else
    add_check pass permissions rm_scope "no broad Bash(rm:*) entries"
  fi

  _write_hits=$(_any_has 'Write(*)')
  _edit_hits=$(_any_has 'Edit(*)')
  _write_surface=""
  [ -n "$_write_hits" ] && _write_surface="Write(*) in $_write_hits"
  [ -n "$_edit_hits" ] && _write_surface="${_write_surface:+$_write_surface; }Edit(*) in $_edit_hits"
  if [ -n "$_write_surface" ]; then
    if [ "$_write_hook_ok" -eq 0 ]; then
      add_check pass permissions write_scope "$_write_surface (check-write.sh hook wired, secrets and system paths are blocked)"
    else
      add_check warn permissions write_scope "$_write_surface AND no Write/Edit guard hook wired. Agents can touch .env, ~/.ssh, /etc. See SECURITY.md 'Manual wire-up for existing installs'."
    fi
  else
    add_check pass permissions write_scope "no broad Write(*)/Edit(*) entries"
  fi

  # Informational: allowlisted-by-binary entries rely on the block rules
  # (after PR #139 block runs before allowlist). No action unless the
  # Bash hook is not wired.
  _find_hits=$(_any_has 'Bash(find:*)')
  _curl_hits=$(_any_has 'Bash(curl:*)')
  _allow_surface=""
  [ -n "$_find_hits" ] && _allow_surface="Bash(find:*)"
  [ -n "$_curl_hits" ] && _allow_surface="${_allow_surface:+$_allow_surface, }Bash(curl:*)"
  if [ -n "$_allow_surface" ]; then
    if [ "$_bash_hook_ok" -eq 0 ]; then
      add_check pass permissions allowlist_scope "$_allow_surface present (guard block rules run before allowlist)"
    else
      add_check warn permissions allowlist_scope "$_allow_surface present AND no Bash guard hook wired. find . -delete and curl | sh will not be blocked. See SECURITY.md."
    fi
  else
    add_check pass permissions allowlist_scope "no broad find/curl entries"
  fi

  # Hook presence: separate rows so the report reads clearly even when
  # all perm rows are pass.
  if [ "$_bash_hook_ok" -eq 0 ]; then
    add_check pass permissions bash_guard "check-dangerous.sh wired as PreToolUse for Bash"
  else
    add_check warn permissions bash_guard "check-dangerous.sh NOT wired. Add the Bash matcher from SECURITY.md 'Manual wire-up'."
  fi
  if [ "$_write_hook_ok" -eq 0 ]; then
    add_check pass permissions write_guard "check-write.sh wired as PreToolUse for Write|Edit|MultiEdit"
  else
    add_check warn permissions write_guard "check-write.sh NOT wired. Add the Write|Edit|MultiEdit matcher from SECURITY.md 'Manual wire-up'."
  fi
fi

# ─── 7. Host protection level ──────────────────────────────────────────
# Detect which host CLIs are installed, look up each one's declared
# capabilities from adapters/<host>.json, and cross-check against what
# this install actually does. The "observation overrides declaration"
# rule from reference/host-adapter-schema.md applies: if Claude's
# adapter declares bash_guard=enforced but the local settings.json
# lacks the hook, the user gets the lower observed capability, not the
# stale promise.

_adapters_dir="$NANO_SKILL_DIR/adapters"

_capability_label() {
  case "$1" in
    enforced)          echo "Blocked when unsafe (L3)" ;;
    hooked)            echo "Guarded (L2)" ;;
    detectable)        echo "Checked (L1)" ;;
    instructions_only) echo "Guided (L0)" ;;
    unsupported)       echo "Not available" ;;
    host_dependent)    echo "Depends on host config" ;;
    *)                 echo "$1" ;;
  esac
}

if [ ! -d "$_adapters_dir" ]; then
  add_check warn host adapters_present "adapters/ directory missing at $_adapters_dir; reinstall to get capability declarations."
else
  _detected_hosts=""
  command -v claude   >/dev/null 2>&1 && _detected_hosts="$_detected_hosts claude"
  command -v codex    >/dev/null 2>&1 && _detected_hosts="$_detected_hosts codex"
  command -v cursor   >/dev/null 2>&1 && _detected_hosts="$_detected_hosts cursor"
  command -v opencode >/dev/null 2>&1 && _detected_hosts="$_detected_hosts opencode"
  command -v gemini   >/dev/null 2>&1 && _detected_hosts="$_detected_hosts gemini"
  _detected_hosts=$(echo "$_detected_hosts" | sed 's/^[[:space:]]*//')

  if [ -z "$_detected_hosts" ]; then
    add_check pass host detected "no agent CLI found; nanostack is installed but the agent it runs in is the source of protection."
  else
    for _host in $_detected_hosts; do
      _adapter="$_adapters_dir/$_host.json"
      if [ ! -f "$_adapter" ]; then
        add_check warn host "${_host}_protection" "no adapter file at adapters/$_host.json. Reinstall or open an issue."
        continue
      fi
      _decl_bash=$(jq -r '.bash_guard'  "$_adapter" 2>/dev/null)
      _decl_write=$(jq -r '.write_guard' "$_adapter" 2>/dev/null)
      _decl_phase=$(jq -r '.phase_gate'  "$_adapter" 2>/dev/null)
      _verif=$(jq -r '.verification.method // "unknown"' "$_adapter" 2>/dev/null)

      # Observation override: only Claude has a local settings.json
      # whose contents we can read to confirm the declaration. For
      # every other host the declaration is the best we have today
      # (verified at last_verified, no runtime cross-check possible
      # from inside the agent's own process).
      _obs_bash="$_decl_bash"
      _obs_write="$_decl_write"
      if [ "$_host" = "claude" ]; then
        if [ -n "$_settings_paths" ]; then
          if [ "$_decl_bash" = "enforced" ] && [ "$_bash_hook_ok" -ne 0 ]; then
            _obs_bash="instructions_only"
          fi
          if [ "$_decl_write" = "enforced" ] && [ "$_write_hook_ok" -ne 0 ]; then
            _obs_write="instructions_only"
          fi
        fi
      fi

      _label_bash=$(_capability_label "$_obs_bash")
      _label_write=$(_capability_label "$_obs_write")
      _label_phase=$(_capability_label "$_decl_phase")

      _drift=""
      [ "$_decl_bash"  != "$_obs_bash"  ] && _drift="${_drift:+$_drift; }bash declared $_decl_bash but observed $_obs_bash"
      [ "$_decl_write" != "$_obs_write" ] && _drift="${_drift:+$_drift; }write declared $_decl_write but observed $_obs_write"

      _detail="bash=$_label_bash, write=$_label_write, phase=$_label_phase, verification=$_verif"
      if [ -n "$_drift" ]; then
        add_check warn host "${_host}_protection" "$_detail. Drift: $_drift. Run /nano-doctor --fix to wire missing hooks."
      else
        case "$_obs_bash" in
          enforced) add_check pass host "${_host}_protection" "$_detail" ;;
          *)        add_check pass host "${_host}_protection" "$_detail (workflow is guided, not enforced, on this host)" ;;
        esac
      fi
    done
  fi
fi

# ─── 8. Worker reachability ────────────────────────────────────────────

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

# ─── 9. Hook wire-up under --fix ───────────────────────────────────────
# When the user passes --fix and the bash_guard or write_guard rows
# warned, write the missing PreToolUse entry into the local
# .claude/settings.json. Round 4 audit asked for migration to be a
# guided action, not "edit JSON by hand". This runs ONLY against the
# project-local settings (not ~/.claude/settings.json) and only after
# making a timestamped backup. jq merges into existing hooks rather
# than replacing them.

if $FIX_MODE && command -v jq >/dev/null 2>&1; then
  _local_settings=".claude/settings.json"
  if [ -f "$_local_settings" ]; then
    _need_bash=0
    _need_write=0
    if ! jq -e '
      (.hooks.PreToolUse // [])
      | any(
          (.matcher // "" | test("Bash"))
          and ((.hooks // []) | any((.command // "") | contains("check-dangerous.sh")))
        )
    ' "$_local_settings" >/dev/null 2>&1; then
      _need_bash=1
    fi
    if ! jq -e '
      (.hooks.PreToolUse // [])
      | any(
          (.matcher // "" | test("Write|Edit"))
          and ((.hooks // []) | any((.command // "") | contains("check-write.sh")))
        )
    ' "$_local_settings" >/dev/null 2>&1; then
      _need_write=1
    fi

    if [ "$_need_bash" -eq 1 ] || [ "$_need_write" -eq 1 ]; then
      _backup="$_local_settings.$(date +%Y%m%d-%H%M%S).bak"
      if cp "$_local_settings" "$_backup" 2>/dev/null; then
        _bashcmd="$HOME/.claude/skills/nanostack/guard/bin/check-dangerous.sh"
        _writecmd="$HOME/.claude/skills/nanostack/guard/bin/check-write.sh"
        _tmp="$_local_settings.tmp.$$"
        if jq \
            --arg bashcmd "$_bashcmd" \
            --arg writecmd "$_writecmd" \
            --argjson need_bash "$_need_bash" \
            --argjson need_write "$_need_write" '
          .hooks //= {}
          | .hooks.PreToolUse //= []
          | if $need_bash == 1 then
              .hooks.PreToolUse += [{
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": $bashcmd}]
              }]
            else . end
          | if $need_write == 1 then
              .hooks.PreToolUse += [{
                "matcher": "Write|Edit|MultiEdit",
                "hooks": [{"type": "command", "command": $writecmd}]
              }]
            else . end
        ' "$_local_settings" > "$_tmp" 2>/dev/null && mv "$_tmp" "$_local_settings"; then
          _added=""
          [ "$_need_bash" -eq 1 ] && _added="Bash"
          [ "$_need_write" -eq 1 ] && _added="${_added:+$_added + }Write|Edit|MultiEdit"
          add_fix "Wired $_added PreToolUse hook(s) into $_local_settings (backup: $_backup). Restart your agent to apply."
        else
          rm -f "$_tmp" 2>/dev/null
          add_fix "Tried to wire hooks into $_local_settings but jq merge failed. Restored from backup not needed (original untouched)."
        fi
      else
        add_fix "Tried to wire hooks but could not write backup of $_local_settings. Skipped."
      fi
    fi
  fi
fi

# ─── Output ────────────────────────────────────────────────────────────

if $JSON_OUTPUT; then
  # Build the entire envelope with jq. Tab-separated CHECK_LINES split
  # cleanly even when detail strings contain pipes or quotes. Round 4
  # audit caught the previous awk -F'|' truncating "Write|Edit|MultiEdit"
  # at the first |; jq -R -s split keeps the field intact.
  _overall="pass"
  if [ "$FAIL" -gt 0 ]; then _overall="fail"
  elif [ "$WARN" -gt 0 ]; then _overall="warn"
  fi

  # fix_available is true when at least one warn/fail row sits in a
  # category --fix can repair (home permissions, sender_executable,
  # bash_guard, write_guard). The user-facing skill needs a single
  # bit to decide whether to even mention --fix.
  _fix_available="false"
  _fix_targets="permissions:bash_guard permissions:write_guard install:sender_executable home:permissions"
  while IFS=$'\t' read -r _s _c _n _d; do
    [ -z "$_s" ] && continue
    [ "$_s" = "pass" ] && continue
    for _t in $_fix_targets; do
      if [ "${_c}:${_n}" = "$_t" ]; then
        _fix_available="true"
        break
      fi
    done
    [ "$_fix_available" = "true" ] && break
  done <<EOF
$CHECK_LINES
EOF

  # Pick up the project session profile if one exists in CWD. The
  # session snippet lives in NANOSTACK_STORE; tolerate its absence.
  _session_profile="null"
  for _sf in ".nanostack/session.json" "$HOME/.nanostack/session.json"; do
    if [ -f "$_sf" ]; then
      _sp=$(jq -r '.profile // empty' "$_sf" 2>/dev/null)
      if [ -n "$_sp" ]; then
        _session_profile="\"$_sp\""
        break
      fi
    fi
  done

  printf '%s' "$CHECK_LINES" | jq -R -s \
    --arg overall "$_overall" \
    --argjson pass "$PASS" \
    --argjson warn "$WARN" \
    --argjson fail "$FAIL" \
    --argjson fix_available "$_fix_available" \
    --argjson session_profile "$_session_profile" '
      split("\n")
      | map(select(length > 0))
      | map(split("\t"))
      | map({status:.[0], category:.[1], name:.[2], detail:.[3]}) as $checks
      | {
          overall: $overall,
          pass: $pass, warn: $warn, fail: $fail,
          checks: $checks,
          fix_available: $fix_available,
          fix_command: (if $fix_available then "nano-doctor.sh --fix" else null end),
          session_profile: $session_profile
        }
    '
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
  printf '%s' "$CHECK_LINES" | while IFS=$'\t' read -r status category name detail; do
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
