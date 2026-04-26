#!/usr/bin/env bash
# check-custom-stack-examples.sh — Static contract for stack examples
# under examples/custom-stack-template/. Validates the manifest
# schema, the README structure, the skill folder layout, and the
# absence of committed runtime artifacts. Run on every PR via the
# custom-stack-examples-contract lint job.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE_ROOT="$REPO_ROOT/examples/custom-stack-template"

PASS=0
FAIL=0

ok()    { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
fail()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# 1. Top-level README exists.
if [ -f "$TEMPLATE_ROOT/README.md" ]; then
  ok "examples/custom-stack-template/README.md exists"
else
  fail "examples/custom-stack-template/README.md missing"
fi

# 2. At least one stack folder exists. Validate every stack found.
shopt -s nullglob 2>/dev/null || true
stack_dirs=()
for d in "$TEMPLATE_ROOT"/*/; do
  [ -f "$d/stack.json" ] || continue
  stack_dirs+=("${d%/}")
done

if [ "${#stack_dirs[@]}" -eq 0 ]; then
  fail "no stack found under examples/custom-stack-template/<name>/stack.json"
  exit 1
fi

for stack_dir in "${stack_dirs[@]}"; do
  stack_name=$(basename "$stack_dir")
  printf '\n[stack: %s]\n' "$stack_name"

  # 3. Stack README exists.
  if [ -f "$stack_dir/README.md" ]; then
    ok "$stack_name/README.md exists"
  else
    fail "$stack_name/README.md missing"
    continue
  fi

  # 4. stack.json parses.
  if ! jq . "$stack_dir/stack.json" >/dev/null 2>&1; then
    fail "$stack_name/stack.json does not parse"
    continue
  fi
  ok "$stack_name/stack.json parses"

  # 5. kind == custom_stack_example.
  kind=$(jq -r '.kind // "missing"' "$stack_dir/stack.json")
  if [ "$kind" = "custom_stack_example" ]; then
    ok "$stack_name kind is custom_stack_example"
  else
    fail "$stack_name kind is '$kind', expected custom_stack_example"
  fi

  # 6. schema_version == "1".
  sv=$(jq -r '.schema_version // "missing"' "$stack_dir/stack.json")
  if [ "$sv" = "1" ]; then
    ok "$stack_name schema_version is 1"
  else
    fail "$stack_name schema_version is '$sv', expected 1"
  fi

  # 7. name matches phase regex.
  manifest_name=$(jq -r '.name // ""' "$stack_dir/stack.json")
  if printf '%s' "$manifest_name" | grep -qE '^[a-z][a-z0-9-]*$'; then
    ok "$stack_name manifest .name '$manifest_name' matches phase regex"
  else
    fail "$stack_name manifest .name '$manifest_name' does not match phase regex"
  fi

  # 8. Each skills[].name is unique and matches the phase regex.
  skill_names=$(jq -r '.skills[]?.name' "$stack_dir/stack.json")
  if [ -z "$skill_names" ]; then
    fail "$stack_name has no skills[]"
    continue
  fi
  dupes=$(printf '%s\n' "$skill_names" | sort | uniq -d)
  if [ -n "$dupes" ]; then
    fail "$stack_name skills[].name contains duplicates: $(echo "$dupes" | tr '\n' ' ')"
  else
    ok "$stack_name skills[].name are unique"
  fi
  bad_skill_names=""
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    if ! printf '%s' "$n" | grep -qE '^[a-z][a-z0-9-]*$'; then
      bad_skill_names="$bad_skill_names $n"
    fi
  done <<< "$skill_names"
  if [ -z "$bad_skill_names" ]; then
    ok "$stack_name all skills[].name match phase regex"
  else
    fail "$stack_name skills[].name fail phase regex:$bad_skill_names"
  fi

  # 9. Each skills[].path exists and contains SKILL.md.
  while IFS=$'\t' read -r skill_name skill_path concurrency; do
    [ -z "$skill_name" ] && continue
    full_path="$stack_dir/$skill_path"
    if [ ! -d "$full_path" ]; then
      fail "$stack_name/$skill_name path '$skill_path' does not exist"
      continue
    fi
    if [ ! -f "$full_path/SKILL.md" ]; then
      fail "$stack_name/$skill_name $skill_path/SKILL.md missing"
      continue
    fi
    # Skill directory basename matches manifest name.
    if [ "$(basename "$full_path")" != "$skill_name" ]; then
      fail "$stack_name/$skill_name path basename '$(basename "$full_path")' != manifest name '$skill_name'"
    else
      ok "$stack_name/$skill_name path basename matches manifest name"
    fi
    # SKILL.md frontmatter name matches.
    fm_name=$(awk '/^---[[:space:]]*$/{f++; next} f==1' "$full_path/SKILL.md" \
      | grep -E '^name:[[:space:]]' | head -1 | sed 's/^name:[[:space:]]*//')
    if [ "$fm_name" = "$skill_name" ]; then
      ok "$stack_name/$skill_name SKILL.md frontmatter name matches"
    else
      fail "$stack_name/$skill_name SKILL.md frontmatter name is '$fm_name', expected '$skill_name'"
    fi
    # SKILL.md frontmatter concurrency matches manifest.
    fm_conc=$(awk '/^---[[:space:]]*$/{f++; next} f==1' "$full_path/SKILL.md" \
      | grep -E '^concurrency:[[:space:]]' | head -1 | sed 's/^concurrency:[[:space:]]*//')
    if [ "$fm_conc" = "$concurrency" ]; then
      ok "$stack_name/$skill_name concurrency matches manifest"
    else
      fail "$stack_name/$skill_name concurrency '$fm_conc' does not match manifest '$concurrency'"
    fi
    # agents/openai.yaml exists with the three discovery keys.
    oy="$full_path/agents/openai.yaml"
    if [ ! -f "$oy" ]; then
      fail "$stack_name/$skill_name agents/openai.yaml missing"
    else
      ok "$stack_name/$skill_name agents/openai.yaml exists"
      oy_fail=0
      for k in display_name short_description default_prompt; do
        grep -qE "^[[:space:]]+${k}:" "$oy" || { oy_fail=1; fail "$stack_name/$skill_name openai.yaml missing key '$k'"; }
      done
      [ "$oy_fail" -eq 0 ] && ok "$stack_name/$skill_name openai.yaml has display_name + short_description + default_prompt"
    fi
    # bin/smoke.sh exists and is executable.
    smoke="$full_path/bin/smoke.sh"
    if [ -x "$smoke" ]; then
      ok "$stack_name/$skill_name bin/smoke.sh is executable"
    else
      fail "$stack_name/$skill_name bin/smoke.sh missing or not executable"
    fi
    # At least one bin/*.sh besides smoke.sh exists.
    other_helpers=0
    for s in "$full_path/bin"/*.sh; do
      [ -f "$s" ] || continue
      [ "$(basename "$s")" = "smoke.sh" ] && continue
      other_helpers=$((other_helpers + 1))
    done
    if [ "$other_helpers" -ge 1 ]; then
      ok "$stack_name/$skill_name has at least one work-helper besides smoke.sh"
    else
      fail "$stack_name/$skill_name has no work-helper script besides smoke.sh"
    fi
    # Every bin/*.sh passes bash -n.
    bin_n_fail=0
    for s in "$full_path/bin"/*.sh; do
      [ -f "$s" ] || continue
      bash -n "$s" 2>/dev/null || { bin_n_fail=1; fail "$stack_name/$skill_name bash -n fails on $(basename "$s")"; }
    done
    [ "$bin_n_fail" -eq 0 ] && ok "$stack_name/$skill_name bash -n passes on every bin/*.sh"
  done < <(jq -r '.skills[]? | "\(.name)\t\(.path)\t\(.concurrency)"' "$stack_dir/stack.json")

  # 10. phase_graph membership: every phase_graph[].name is core ∪ build ∪ skills.
  core_phases="think plan review qa security ship"
  graph_names=$(jq -r '.phase_graph[]?.name' "$stack_dir/stack.json")
  bad_graph=""
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    case " $core_phases build " in
      *" $g "*) continue ;;
    esac
    if ! printf '%s\n' "$skill_names" | grep -qFx "$g"; then
      bad_graph="$bad_graph $g"
    fi
  done <<< "$graph_names"
  if [ -z "$bad_graph" ]; then
    ok "$stack_name phase_graph names are all core/build/skill"
  else
    fail "$stack_name phase_graph contains unknown names:$bad_graph"
  fi

  # 11. ship depends on the stack's composer (if there is a release-readiness
  #     skill, ship must depend on it, not directly on the review/security/qa
  #     trio). Spec rule for this stack; future stacks may declare a
  #     different composer in stack.json — for now the rule applies when the
  #     skill is named release-readiness.
  if printf '%s\n' "$skill_names" | grep -qFx "release-readiness"; then
    ship_deps=$(jq -r '.phase_graph[]? | select(.name == "ship") | .depends_on[]?' "$stack_dir/stack.json")
    if [ -n "$ship_deps" ] && printf '%s\n' "$ship_deps" | grep -qFx "release-readiness"; then
      ok "$stack_name ship depends on release-readiness"
    else
      fail "$stack_name ship does not depend on release-readiness (got: $ship_deps)"
    fi
  fi

  # 12. README has the six required H2 sections.
  for h in "Who this stack is for" "What it adds" "Install in a sandbox" \
           "Run the workflow" "Expected evidence" "Reset"; do
    if grep -qE "^##[[:space:]]+${h}\$" "$stack_dir/README.md"; then
      ok "$stack_name README has '## $h' section"
    else
      fail "$stack_name README missing '## $h' section"
    fi
  done

  # 13. README mentions the four required tokens.
  for tok in "bin/create-skill.sh" "bin/check-custom-skill.sh" \
             "conductor/bin/sprint.sh" "release-readiness"; do
    if grep -qF "$tok" "$stack_dir/README.md"; then
      ok "$stack_name README mentions '$tok'"
    else
      fail "$stack_name README missing token '$tok'"
    fi
  done

  # 14. No committed runtime artifacts under the stack tree.
  rogue_paths=()
  for unsafe in ".nanostack" "node_modules" ".env" ".env.local" \
                ".env.production" ".env.staging" "*.log"; do
    while IFS= read -r m; do
      [ -n "$m" ] && rogue_paths+=("$m")
    done < <(find "$stack_dir" -name "$unsafe" -not -path "*/.git/*" 2>/dev/null)
  done
  # Also detect credential JSON basenames that the bash guard blocks.
  while IFS= read -r m; do
    [ -n "$m" ] && rogue_paths+=("$m")
  done < <(find "$stack_dir" -type f \( \
    -iname "credentials.json" -o -iname "secrets.json" -o \
    -iname "secret.json"      -o -iname "credential.json" -o \
    -iname "service-account.json" -o -iname "service_account.json" -o \
    -iname "firebase-adminsdk.json" -o \
    -iname "google-credentials.json" -o -iname "gcp-credentials.json" -o \
    -iname "aws-credentials.json"   -o -iname "supabase-service-role.json" -o \
    -iname "client_secret.json"     -o -iname "client-secret.json" -o \
    -iname "client-secrets.json" \
  \) -not -path "*/.git/*" 2>/dev/null)
  if [ "${#rogue_paths[@]}" -eq 0 ]; then
    ok "$stack_name has no committed runtime artifacts"
  else
    fail "$stack_name has committed runtime artifacts: ${rogue_paths[*]}"
  fi
done

printf '\n=========================\n'
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf 'Custom Stack Examples contract: %d checks passed, 0 failed\n' "$PASS"
  exit 0
fi
printf 'Custom Stack Examples contract: %d failed of %d total\n' "$FAIL" "$TOTAL"
exit 1
