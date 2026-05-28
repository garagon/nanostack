#!/usr/bin/env bash
# check-adapters.sh — Validate adapters/<host>.json files.
#
# PR 6 of the 2026-05-10 architecture audit. Adapters declare what a
# given host (claude, codex, cursor, opencode, gemini, ...) actually
# enforces for the Bash guard, write guard, and phase gate. This
# script validates schema + capability enum membership + last_verified
# freshness and surfaces drift before it reaches a release.
#
# Usage:
#   bin/check-adapters.sh                       Validate every adapters/*.json.
#   bin/check-adapters.sh <host>                Validate one adapter.
#   bin/check-adapters.sh --json                Machine-readable summary.
#   bin/check-adapters.sh --require-readme-contracts
#                                               Strict mode (for CI): also
#       require that the schema file, the README per-host matrix, and the
#       README L-level legend are PRESENT, not just consistent when present.
#       Without this flag the README/schema-derived locks skip when a file
#       or table is absent, so an isolated partial checkout still validates
#       adapter JSON shape. The live lint/e2e jobs pass this flag so the
#       contracts cannot be silently disabled by deleting a table.
#
# Freshness policy:
#   - warn after 30 days
#   - fail after 60 days for README-listed adapters
#   - manual override: NANOSTACK_ALLOW_STALE_ADAPTERS=1 downgrades the
#     fail to a warning. Not for CI; intended for `bin/check-adapters.sh`
#     when a maintainer is explicitly re-running on an old branch.
#
# Exit code:
#   0  all adapters validate within the freshness window
#   1  any adapter is malformed, missing a required key, has a value
#      outside the enum, has unparseable last_verified, or is stale
#      beyond the README-fail threshold
set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NANOSTACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER_DIR="$NANOSTACK_ROOT/adapters"

WARN_DAYS=30
FAIL_DAYS=60

JSON_OUT=false
REQUIRE_CONTRACTS=false
FILTER=""
for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUT=true ;;
    --require-readme-contracts) REQUIRE_CONTRACTS=true ;;
    -h|--help)
      sed -n '/^# /,/^$/p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) FILTER="$arg" ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

if [ ! -d "$ADAPTER_DIR" ]; then
  echo "ERROR: $ADAPTER_DIR does not exist" >&2
  exit 1
fi

# Known hosts and accepted capability enum values. The capability
# values come from reference/host-adapter-schema.md; bash/write/phase
# all share the same enum. Codex caught the earlier drift on the
# PR 6 first review pass — the docs accepted `detectable`,
# `hooked`, and `host_dependent` while the script was rejecting
# them.
KNOWN_HOSTS="claude cursor codex opencode gemini"
ENFORCEMENT_ENUM="unsupported instructions_only detectable hooked enforced host_dependent"
DISCOVERY_ENUM="native rules_file extension skill_folder instructions_only unsupported unknown host_dependent"
VERIFICATION_METHOD_ENUM="ci manual unknown"
# Supported schema versions. Bump here when the schema doc adds a new
# version and update downstream consumers in the same commit so an
# adapter cannot ship a future-incompatible shape silently.
SCHEMA_VERSION_ENUM="1"

# Adapter names listed in the README. Adapters in this list get the
# strict fail-after-60 policy; an adapter not listed in the README is
# advisory only. Path is anchored at $NANOSTACK_ROOT so the lookup
# does not depend on the caller's cwd (Codex flagged this on the
# PR 6 third review pass — a script invoked from outside the repo
# was producing an empty list and silently downgrading fails to
# warns).
README_LISTED=$(grep -oE '`(claude|cursor|codex|opencode|gemini)`' "$NANOSTACK_ROOT/README.md" 2>/dev/null \
  | tr -d '`' | sort -u | tr '\n' ' ')

README_FILE="$NANOSTACK_ROOT/README.md"
SCHEMA_FILE="$NANOSTACK_ROOT/reference/host-adapter-schema.md"
WORKFLOW_DIR="$NANOSTACK_ROOT/.github/workflows"
BT='`'

# ---- L-level vocabulary, parsed from the host adapter schema ----
# PR 2 of the 2026-05-28 architecture follow-up. reference/host-adapter-schema.md
# is the single source of truth for the capability -> L-level -> label
# mapping. Parse it once here so the README legend and per-host matrix can
# be validated against it instead of a second hardcoded copy that could
# drift. The bullet lines look like:
#   - `unsupported` and `instructions_only` are L0 ("Guided")
#   - `enforced` is L3 ("Enforced")
#   - L4 ("Continuously verified") is not a capability value ...
# When the schema is absent (partial checkout, or a test fixture that does
# not ship it) the README-derived checks that need it are skipped: they
# cannot run without the source of truth, and the live repo always ships
# the schema so the real lock still fires.
SCHEMA_PRESENT=false
SCHEMA_PARSE_OK=false
CAP_LEVEL_MAP=""    # newline list of "cap<TAB>level"
LEVEL_LABEL_MAP=""  # newline list of "level<TAB>label"

# Normalize a cell/label for comparison: lowercase, strip backticks,
# trim and collapse internal whitespace.
norm_label() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '`' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
}

if [ -f "$SCHEMA_FILE" ]; then
  SCHEMA_PRESENT=true
  SCHEMA_PARSE_OK=true
  for _cap in unsupported instructions_only detectable hooked enforced; do
    _bullet=$(grep -E '^- ' "$SCHEMA_FILE" | grep -F "${BT}${_cap}${BT}" | grep -E 'L[0-9] \("' | head -1)
    _lvl=$(printf '%s\n' "$_bullet" | sed -nE 's/.* L([0-9]) \(".*/\1/p' | head -1)
    _lbl=$(printf '%s\n' "$_bullet" | sed -nE 's/.*\("([^"]+)"\).*/\1/p' | head -1)
    if [ -z "$_lvl" ] || [ -z "$_lbl" ]; then
      SCHEMA_PARSE_OK=false
      continue
    fi
    CAP_LEVEL_MAP="${CAP_LEVEL_MAP}${_cap}	${_lvl}
"
    case "
$LEVEL_LABEL_MAP" in
      *"
${_lvl}	"*) : ;;
      *) LEVEL_LABEL_MAP="${LEVEL_LABEL_MAP}${_lvl}	${_lbl}
" ;;
    esac
  done
  _l4=$(grep -E '^- L4 \("' "$SCHEMA_FILE" | head -1)
  _l4lbl=$(printf '%s\n' "$_l4" | sed -nE 's/.*\("([^"]+)"\).*/\1/p' | head -1)
  if [ -n "$_l4lbl" ]; then
    LEVEL_LABEL_MAP="${LEVEL_LABEL_MAP}4	${_l4lbl}
"
  else
    # A schema that ships but loses the L4 bullet is incomplete: the
    # legend check would skip L4 and strict mode would still pass with a
    # truncated vocabulary. Treat it as a parse failure so the integrity
    # guard fires instead of silently dropping the L4 lock.
    SCHEMA_PARSE_OK=false
  fi
fi

cap_level()   { printf '%s' "$CAP_LEVEL_MAP"   | awk -F'\t' -v k="$1" '$1==k{print $2; exit}'; }
level_label() { printf '%s' "$LEVEL_LABEL_MAP" | awk -F'\t' -v k="$1" '$1==k{print $2; exit}'; }

# ---- Continuously-triggered CI job names ----
# The evidence gate only counts a ci_jobs entry as proof if it names a
# real job (a key under `jobs:`) in a workflow that runs on every change
# (its `on:` block includes pull_request or push). A job that only exists
# under `on:` (e.g. pull_request), or one that lives in a
# workflow_dispatch-only workflow, is NOT continuous evidence: a hook that
# is only exercised when a maintainer manually runs a workflow is not
# "CI-asserted on every change". The awk tracks which top-level section
# (on/jobs/other) each line belongs to so an `on:` trigger key is never
# mistaken for a job key.
WORKFLOW_JOBS=""
if [ -d "$WORKFLOW_DIR" ]; then
  for _wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
    [ -f "$_wf" ] || continue
    _wf_jobs=$(awk '
      /^[A-Za-z_][A-Za-z0-9_-]*:/ {
        if ($0 ~ /^jobs:[[:space:]]*$/)      sect="jobs"
        else if ($0 ~ /^on:/)                sect="on"
        else                                  sect="other"
        next
      }
      sect=="on" && /^  (pull_request|push):/ { cont=1 }
      sect=="jobs" && /^  [A-Za-z0-9_-]+:/ { l=$0; sub(/^  /,"",l); sub(/:.*/,"",l); jobs=jobs l "\n" }
      END { if (cont) printf "%s", jobs }
    ' "$_wf")
    WORKFLOW_JOBS="${WORKFLOW_JOBS}${_wf_jobs}"
  done
fi

# Exact (non-regex) membership test against the continuous job set.
job_is_continuous() {
  printf '%s\n' "$WORKFLOW_JOBS" | grep -Fxq "$1"
}

# Expected README matrix cell (normalized) for an adapter capability
# value, e.g. enforced -> "enforced (l3)", instructions_only ->
# "guided (l0)". host_dependent varies and is skipped.
expected_cell() {
  local cap="$1" lvl lbl
  [ "$cap" = "host_dependent" ] && { printf '__SKIP__'; return; }
  lvl=$(cap_level "$cap"); [ -z "$lvl" ] && { printf '__UNKNOWN__'; return; }
  lbl=$(level_label "$lvl"); [ -z "$lbl" ] && { printf '__UNKNOWN__'; return; }
  norm_label "$lbl (l$lvl)"
}

# Map an adapter host key to its display name in the README matrix.
host_display_name() {
  case "$1" in
    claude)   printf 'Claude Code' ;;
    cursor)   printf 'Cursor' ;;
    codex)    printf 'OpenAI Codex' ;;
    opencode) printf 'OpenCode' ;;
    gemini)   printf 'Gemini CLI' ;;
    *)        printf '' ;;
  esac
}

readme_has_matrix() {
  [ -f "$README_FILE" ] && grep -qE '^\| *Agent *\| *Bash guard *\|' "$README_FILE"
}
readme_has_legend() {
  [ -f "$README_FILE" ] && grep -qE '^\| *Level *\| *Meaning *\|' "$README_FILE"
}
matrix_row_for() {
  grep -E "^\| *$1 *\|" "$README_FILE" 2>/dev/null | grep -E '\(L[0-9]\)' | head -1
}

NOW_EPOCH=$(date -u +%s)

in_enum() {
  local val="$1" enum="$2"
  case " $enum " in
    *" $val "*) return 0 ;;
  esac
  return 1
}

parse_iso_date() {
  local d="$1"
  # Strict ISO YYYY-MM-DD only. GNU `date -d` accepts non-ISO values
  # like "yesterday" or "04/25/2026", which would let a malformed
  # last_verified slip through the freshness gate on the Ubuntu
  # CI runner. The shape check rejects those before parsing.
  # Codex caught the permissive parse on the PR 6 seventh review pass.
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 0 ;;
  esac
  if command -v gdate >/dev/null 2>&1; then
    gdate -u -d "$d" +%s 2>/dev/null
  else
    date -u -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null \
      || date -u -d "$d" +%s 2>/dev/null
  fi
}

FAIL=0
WARN=0
RESULTS_JSON="[]"
RESULTS_TEXT=""
FILTER_MATCHED=0

check_adapter() {
  local file="$1"
  local name
  name=$(basename "$file" .json)

  if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    return 0
  fi
  [ -n "$FILTER" ] && FILTER_MATCHED=1

  local host last_verified bash_guard write_guard phase_gate discovery method
  if ! jq -e '.' "$file" >/dev/null 2>&1; then
    record_result "$name" "fail" "invalid JSON" "" 0
    return 0
  fi
  # The root must be an object. A valid-JSON array (`[]`) or scalar
  # used to pass this gate and crash the next jq read under set -e.
  # Codex flagged the type hole on the PR 6 sixth review pass.
  if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    record_result "$name" "fail" "root is not a JSON object" "" 0
    return 0
  fi

  host=$(jq -r '.host // ""' "$file")
  last_verified=$(jq -r '.last_verified // ""' "$file")
  bash_guard=$(jq -r '.bash_guard // ""' "$file")
  write_guard=$(jq -r '.write_guard // ""' "$file")
  phase_gate=$(jq -r '.phase_gate // ""' "$file")
  discovery=$(jq -r '.skill_discovery // ""' "$file")
  # `.verification.method` is read inside the type-guarded block below
  # so a non-object verification (e.g. a string) does not crash jq
  # before record_result lands. Codex flagged the unguarded access on
  # the PR 6 fifth review pass.

  local errors=""
  # Full required-field list from reference/host-adapter-schema.md.
  # Codex flagged the truncated check on the PR 6 first review pass:
  # the previous list omitted schema_version, verification,
  # install_target, doctor_checks so an adapter could ship with no
  # verification evidence and still pass.
  for key in host schema_version last_verified verification skill_discovery \
             bash_guard write_guard phase_gate install_target doctor_checks; do
    if ! jq -e --arg k "$key" 'has($k)' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }missing $key"
    fi
  done
  # Scalar required fields must be strings. A wrong scalar type like
  # install_target: 123 used to pass because only key presence was
  # checked. Codex flagged this on the PR 6 sixth review pass.
  for str_key in host schema_version last_verified skill_discovery \
                 bash_guard write_guard phase_gate install_target; do
    if jq -e --arg k "$str_key" 'has($k)' "$file" >/dev/null 2>&1; then
      if ! jq -e --arg k "$str_key" '.[$k] | type == "string"' "$file" >/dev/null 2>&1; then
        errors="${errors:+$errors; }$str_key is not a string"
      fi
    fi
  done

  # schema_version must match a known value. Bumping the schema means
  # adding to SCHEMA_VERSION_ENUM in the same commit that updates
  # downstream consumers, so an adapter cannot ship a future-
  # incompatible shape silently. Codex flagged the missing version
  # check on the PR 6 fourth review pass.
  local schema_v
  schema_v=$(jq -r '.schema_version // ""' "$file")
  if [ -z "$schema_v" ]; then
    errors="${errors:+$errors; }schema_version is empty"
  elif ! in_enum "$schema_v" "$SCHEMA_VERSION_ENUM"; then
    errors="${errors:+$errors; }schema_version=$schema_v not in supported set ($SCHEMA_VERSION_ENUM)"
  fi

  # verification must be an object with method + evidence. The method
  # read is wrapped with `?` and a type guard so a malformed
  # verification (e.g. a string) under set -e cannot make this stage
  # exit before record_result lands. Codex caught the malformed-input
  # crash on the PR 6 fifth review pass.
  if jq -e '.verification | type == "object"' "$file" >/dev/null 2>&1; then
    local v_method
    v_method=$(jq -r '.verification.method? // ""' "$file" 2>/dev/null)
    if [ -z "$v_method" ]; then
      errors="${errors:+$errors; }verification.method is empty"
    elif ! in_enum "$v_method" "$VERIFICATION_METHOD_ENUM"; then
      errors="${errors:+$errors; }verification.method=$v_method not in enum ($VERIFICATION_METHOD_ENUM)"
    fi
    if ! jq -e '.verification.evidence | type == "string" and length > 0' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }verification.evidence is empty or wrong type"
    fi
  elif jq -e 'has("verification")' "$file" >/dev/null 2>&1; then
    # Field exists but is not an object — recorded as a typed failure
    # rather than letting the script exit with a jq error.
    errors="${errors:+$errors; }verification is not an object"
  fi

  # doctor_checks must be a non-empty array of strings. The schema in
  # reference/host-adapter-schema.md says `string[]`; non-string
  # entries pass to downstream doctor/setup code as check names so a
  # numeric or object entry would break runtime lookups. Codex flagged
  # the missing element-type check on the PR 6 third review pass.
  if jq -e 'has("doctor_checks") and (.doctor_checks | type == "array")' "$file" >/dev/null 2>&1; then
    if ! jq -e '.doctor_checks | length > 0' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }doctor_checks is empty"
    elif ! jq -e '.doctor_checks | all(type == "string" and length > 0)' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }doctor_checks must be a non-empty array of strings"
    fi
  elif jq -e 'has("doctor_checks")' "$file" >/dev/null 2>&1; then
    errors="${errors:+$errors; }doctor_checks is not an array"
  fi

  if ! in_enum "$host" "$KNOWN_HOSTS"; then
    errors="${errors:+$errors; }host=$host not in known set ($KNOWN_HOSTS)"
  fi
  # The schema (reference/host-adapter-schema.md) says
  # `adapters/<host>.json` must match the .host field. A mislabeled
  # file (codex.json with host=claude) used to pass and would also
  # satisfy the README missing-file cross-check, so CI could ship a
  # duplicated adapter while claiming the wrong host was verified.
  # Codex flagged this on the PR 6 second review pass.
  if [ "$host" != "$name" ]; then
    errors="${errors:+$errors; }host=$host does not match filename basename=$name"
  fi

  # Empty-string capability values are NOT valid even though the key
  # exists. Codex caught the empty-passes-through hole on the PR 6
  # first review pass: a README-listed adapter with bash_guard=""
  # used to come back OK.
  for field in bash_guard write_guard phase_gate; do
    val=$(eval echo "\$$field")
    if [ -z "$val" ]; then
      errors="${errors:+$errors; }$field is empty"
    elif ! in_enum "$val" "$ENFORCEMENT_ENUM"; then
      errors="${errors:+$errors; }$field=$val not in enum ($ENFORCEMENT_ENUM)"
    fi
  done

  # ---- Evidence gate: enforced/hooked is a behavioral claim ----
  # PR 2 of the 2026-05-28 architecture follow-up. enforced/hooked says a
  # hook actually runs (and, for enforced, blocks). The enum value alone
  # does not prove it, so require CI evidence: verification.method == ci
  # plus a non-empty verification.ci_jobs naming jobs that exist under
  # .github/workflows/. Rule documented in reference/host-adapter-schema.md
  # ("Evidence gate"). Job existence is only checked when a workflow dir is
  # present (the live repo always has one); a fixture without workflows
  # still has its method+ci_jobs shape validated.
  local needs_evidence=""
  for field in bash_guard write_guard phase_gate; do
    val=$(eval echo "\$$field")
    case "$val" in
      enforced|hooked) needs_evidence="${needs_evidence:+$needs_evidence }$field" ;;
    esac
  done
  if [ -n "$needs_evidence" ]; then
    local ev_method
    ev_method=$(jq -r '.verification.method? // ""' "$file" 2>/dev/null)
    if [ "$ev_method" != "ci" ]; then
      errors="${errors:+$errors; }$needs_evidence claim enforced/hooked but verification.method='$ev_method' (must be ci)"
    fi
    if ! jq -e '.verification.ci_jobs | type == "array" and length > 0 and all(type == "string" and length > 0)' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }$needs_evidence claim enforced/hooked but verification.ci_jobs is missing or empty"
    elif [ -d "$WORKFLOW_DIR" ]; then
      local job bad_jobs=""
      while IFS= read -r job; do
        [ -z "$job" ] && continue
        # Reject anything that is not a plain job identifier first, so a
        # value with ERE metacharacters (e.g. ".*") can never be treated
        # as a pattern. Then require exact membership in the set of jobs
        # that exist under `jobs:` in a continuously-triggered workflow.
        if ! printf '%s' "$job" | grep -qE '^[A-Za-z0-9_-]+$'; then
          bad_jobs="${bad_jobs:+$bad_jobs,}'$job' (not a valid job id)"
        elif ! job_is_continuous "$job"; then
          bad_jobs="${bad_jobs:+$bad_jobs,}$job"
        fi
      done <<< "$(jq -r '.verification.ci_jobs[]?' "$file" 2>/dev/null)"
      if [ -n "$bad_jobs" ]; then
        errors="${errors:+$errors; }verification.ci_jobs must name jobs in a pull_request/push-triggered workflow; not satisfied: $bad_jobs"
      fi
    fi
  fi

  # ---- README matrix equality ----
  # The per-host matrix in README.md must show the same capability level
  # as this adapter. Source of truth: the adapter JSON value mapped to the
  # schema's L-level vocabulary. Runs only when the README ships the matrix
  # and the schema parsed (the live repo has both, so the lock fires).
  if $SCHEMA_PARSE_OK && readme_has_matrix; then
    local display
    display=$(host_display_name "$name")
    if [ -n "$display" ]; then
      local row
      row=$(matrix_row_for "$display")
      if [ -z "$row" ]; then
        errors="${errors:+$errors; }README matrix has no row for '$display' but adapter $name exists"
      else
        local idx exp act
        idx=3
        for field in bash_guard write_guard phase_gate; do
          val=$(eval echo "\$$field")
          exp=$(expected_cell "$val")
          if [ "$exp" = "__SKIP__" ]; then idx=$((idx+1)); continue; fi
          if [ "$exp" = "__UNKNOWN__" ]; then
            errors="${errors:+$errors; }cannot map $field=$val to an L-level from the schema"
            idx=$((idx+1)); continue
          fi
          act=$(norm_label "$(printf '%s\n' "$row" | awk -F'|' -v n="$idx" '{print $n}')")
          if [ "$act" != "$exp" ]; then
            errors="${errors:+$errors; }README matrix $field cell for $display is '$act' but $name says '$val' (expected '$exp')"
          fi
          idx=$((idx+1))
        done
      fi
    fi
  fi

  if [ -z "$discovery" ]; then
    # Already reported as missing above when the key was absent. Only
    # flag here if the key exists but the value is empty.
    if jq -e 'has("skill_discovery")' "$file" >/dev/null 2>&1; then
      errors="${errors:+$errors; }skill_discovery is empty"
    fi
  elif ! in_enum "$discovery" "$DISCOVERY_ENUM"; then
    errors="${errors:+$errors; }skill_discovery=$discovery not in enum ($DISCOVERY_ENUM)"
  fi

  local age_days="unknown"
  if [ -n "$last_verified" ]; then
    # Suppress set -e for the parse so we always reach record_result.
    # Codex flagged the silent-exit on the PR 6 first review pass.
    local then_epoch
    set +e
    then_epoch=$(parse_iso_date "$last_verified")
    set -e
    if [ -z "$then_epoch" ]; then
      errors="${errors:+$errors; }last_verified=$last_verified does not parse as a date"
    elif [ "$then_epoch" -gt "$NOW_EPOCH" ]; then
      # A future date silently suppressed every freshness warning
      # because (now - future) is negative. Codex caught this on the
      # PR 6 fifth review pass: a typo like 2099-01-01 used to make
      # an adapter look perpetually fresh.
      errors="${errors:+$errors; }last_verified=$last_verified is in the future"
    else
      age_days=$(( (NOW_EPOCH - then_epoch) / 86400 ))
    fi
  else
    errors="${errors:+$errors; }last_verified is empty"
  fi

  local status="ok"
  if [ -n "$errors" ]; then
    status="fail"
  elif [ "$age_days" != "unknown" ]; then
    if [ "$age_days" -gt "$FAIL_DAYS" ]; then
      case " $README_LISTED " in
        *" $host "*)
          if [ "${NANOSTACK_ALLOW_STALE_ADAPTERS:-0}" = "1" ]; then
            status="warn"
            errors="last_verified is $age_days days old (>$FAIL_DAYS); override active"
          else
            status="fail"
            errors="last_verified is $age_days days old (>$FAIL_DAYS) and $host is README-listed"
          fi
          ;;
        *)
          status="warn"
          errors="last_verified is $age_days days old (>$FAIL_DAYS) but $host is not README-listed"
          ;;
      esac
    elif [ "$age_days" -gt "$WARN_DAYS" ]; then
      status="warn"
      errors="last_verified is $age_days days old (>$WARN_DAYS)"
    fi
  fi

  record_result "$name" "$status" "$errors" "$age_days" "$([ "$age_days" = "unknown" ] && echo 0 || echo "$age_days")"
}

record_result() {
  local name="$1" status="$2" message="$3" age_days="$4" age_int="$5"
  case "$status" in
    fail) FAIL=$((FAIL + 1)) ;;
    warn) WARN=$((WARN + 1)) ;;
  esac
  RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
    --arg name "$name" \
    --arg status "$status" \
    --arg message "$message" \
    --argjson age "${age_int:-0}" \
    '. + [{adapter: $name, status: $status, age_days: $age, message: ($message // "")}]')
  if [ "$status" = "ok" ]; then
    RESULTS_TEXT="${RESULTS_TEXT}OK    $name (age $age_days days)
"
  else
    local label
    label=$(echo "$status" | tr '[:lower:]' '[:upper:]')
    RESULTS_TEXT="${RESULTS_TEXT}${label}  $name: $message
"
  fi
}

for f in "$ADAPTER_DIR"/*.json; do
  [ -f "$f" ] || continue
  check_adapter "$f"
done

# When the caller passed a filter and nothing matched, treat that as a
# failure. Otherwise a typo (`check-adapters.sh codxe`) produced an
# empty summary that exited 0, suggesting CI had validated the
# requested adapter when no file matched. Codex flagged this on the
# PR 6 fourth review pass.
if [ -n "$FILTER" ] && [ "$FILTER_MATCHED" = "0" ]; then
  FAIL=$((FAIL + 1))
  RESULTS_TEXT="${RESULTS_TEXT}FAIL  ${FILTER}: no adapters/${FILTER}.json found (filter matched nothing)
"
  RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
    --arg name "$FILTER" \
    '. + [{adapter: $name, status: "fail", age_days: 0, message: "filter matched no adapter file"}]')
fi

# Cross-check: every README-listed adapter must have a JSON file.
# In single-host mode (caller passed a $FILTER) we only check the
# requested adapter so a partial checkout that mentions other
# adapters in its README does not fail the targeted run. Codex
# flagged the cross-host bleed on the PR 6 eighth review pass.
for host in $README_LISTED; do
  [ -z "$host" ] && continue
  if [ -n "$FILTER" ] && [ "$host" != "$FILTER" ]; then
    continue
  fi
  if [ ! -f "$ADAPTER_DIR/${host}.json" ]; then
    FAIL=$((FAIL + 1))
    RESULTS_TEXT="${RESULTS_TEXT}FAIL  ${host}: listed in README but no adapters/${host}.json
"
    RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
      --arg name "$host" \
      '. + [{adapter: $name, status: "fail", age_days: 0, message: "listed in README but no JSON file"}]')
  fi
done

# ---- Strict mode: the README/schema contracts must be PRESENT ----
# Without --require-readme-contracts the matrix/legend/evidence locks are
# skip-if-absent so an isolated partial checkout can still validate adapter
# JSON shape. The live CI jobs pass the flag, which makes a missing schema,
# missing README matrix, or missing README legend a hard failure: deleting
# a table can no longer turn the contract off. Runs in full mode only; a
# single-host diagnostic (--filter) is not the place to demand the whole
# README.
if $REQUIRE_CONTRACTS && [ -z "$FILTER" ]; then
  contract_fail=""
  if ! $SCHEMA_PRESENT; then
    contract_fail="${contract_fail:+$contract_fail; }schema file reference/host-adapter-schema.md is missing"
  fi
  if [ ! -f "$README_FILE" ]; then
    contract_fail="${contract_fail:+$contract_fail; }README.md is missing"
  else
    readme_has_matrix || contract_fail="${contract_fail:+$contract_fail; }README per-host capability matrix is missing"
    readme_has_legend || contract_fail="${contract_fail:+$contract_fail; }README L-level legend is missing"
  fi
  if [ -n "$contract_fail" ]; then
    FAIL=$((FAIL + 1))
    RESULTS_TEXT="${RESULTS_TEXT}FAIL  readme-contracts: $contract_fail
"
    RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --arg m "$contract_fail" \
      '. + [{adapter: "readme-contracts", status: "fail", age_days: 0, message: $m}]')
  fi
fi

# ---- Schema parse integrity ----
# If the schema ships but its L-level vocabulary could not be parsed, the
# matrix/legend locks silently disable themselves. Fail loudly instead so
# a schema restructure cannot turn the lock off without anyone noticing.
if $SCHEMA_PRESENT && ! $SCHEMA_PARSE_OK; then
  FAIL=$((FAIL + 1))
  RESULTS_TEXT="${RESULTS_TEXT}FAIL  host-adapter-schema: could not parse the capability/L-level vocabulary from reference/host-adapter-schema.md
"
  RESULTS_JSON=$(echo "$RESULTS_JSON" | jq \
    '. + [{adapter: "host-adapter-schema", status: "fail", age_days: 0, message: "could not parse L-level vocabulary"}]')
fi

# ---- README legend vs schema vocabulary ----
# The README L-level legend must use the same level->label words the
# schema defines. Runs once in full mode (no filter) when both the legend
# and the parsed schema are present. Sabotaging either the level numbers
# or the labels in the README legend fails here.
if [ -z "$FILTER" ] && $SCHEMA_PARSE_OK && readme_has_legend; then
  legend_fail=""
  for lvl in 0 1 2 3 4; do
    lbl=$(level_label "$lvl")
    [ -z "$lbl" ] && continue
    legend_row=$(grep -iE "^\| *\*\*L${lvl} " "$README_FILE" | head -1)
    if [ -z "$legend_row" ]; then
      legend_fail="${legend_fail:+$legend_fail; }legend missing row for L$lvl"
      continue
    fi
    got=$(printf '%s\n' "$legend_row" | sed -nE 's/^\| *\*\*L'"$lvl"' ([^*]+)\*\*.*/\1/p' | head -1)
    if [ "$(norm_label "$got")" != "$(norm_label "$lbl")" ]; then
      legend_fail="${legend_fail:+$legend_fail; }legend L$lvl label is '$(norm_label "$got")' but schema says '$(norm_label "$lbl")'"
    fi
  done
  if [ -n "$legend_fail" ]; then
    FAIL=$((FAIL + 1))
    RESULTS_TEXT="${RESULTS_TEXT}FAIL  README-legend: $legend_fail
"
    RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --arg m "$legend_fail" \
      '. + [{adapter: "README-legend", status: "fail", age_days: 0, message: $m}]')
  fi
fi

if $JSON_OUT; then
  jq -n --argjson results "$RESULTS_JSON" --argjson fail "$FAIL" --argjson warn "$WARN" \
    '{adapters: $results, summary: {fail: $fail, warn: $warn}}'
else
  printf '%s' "$RESULTS_TEXT"
  echo "---"
  echo "Summary: $FAIL failed, $WARN warned"
fi

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
