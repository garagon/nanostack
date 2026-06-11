#!/usr/bin/env bash
# e2e-write-guard-regression.sh — Write/Edit guard block/allow regression matrix.
#
# Extracted from the inline `write-guard-regression` job in lint.yml so
# the matrix runs locally through ci/run-harness.sh, not only in CI.
# The cases are the accumulated regression lock for guard/bin/
# check-write.sh: secret basenames and system paths, credential JSON
# basenames at write time (mirroring the G-035 read rule, including
# separator-less, suffixed, and mixed-case variants), template
# exemptions that must keep first-run onboarding usable, the JSON
# stdin contract (Claude Code PreToolUse), and symlink resolution to
# protected targets. Every block case must keep exiting 1 and every
# allow case must keep exiting 0.
#
# HOME and NANOSTACK_STORE point into the suite temp root so the
# session phase gate and any developer-global config cannot change a
# verdict; the $HOME-relative cases expand against the overridden HOME
# and exercise the same prefix rules check-write.sh computes from it.
#
# Exit 0 = all cells pass, exit 1 = any cell failed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/ci/lib/harness.sh"

CHECK_WRITE="$REPO/guard/bin/check-write.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --filter) nh_set_filter "${2:-}"; shift 2 ;;
    --filter=*) nh_set_filter "${1#*=}"; shift ;;
    *) shift ;;
  esac
done

nh_init write-guard-regression nano-writereg
nh_require_cmd jq

WORK="$NH_TMP"
export HOME="$WORK/home"
export NANOSTACK_STORE="$WORK/store"
mkdir -p "$HOME" "$NANOSTACK_STORE" "$WORK/project"

run_case() {
  local expected="$1" path="$2"
  ( cd "$WORK/project" && bash "$CHECK_WRITE" "$path" >/dev/null 2>&1 )
  local got=$?
  if [ "$got" = "$expected" ]; then
    nh_pass "exit=$got  $path"
  else
    nh_fail "$path" "expected exit $expected, got $got"
  fi
}

cell_secrets_and_system() {
  # Blocked: secrets by basename + system paths.
  run_case 1 '.env'
  run_case 1 '.env.local'
  run_case 1 '.env.production'
  run_case 1 '.env.staging'
  run_case 1 '.env.test'
  run_case 1 './secrets/key.pem'
  run_case 1 'path/to/authorized_keys'
  run_case 1 'config.key'
  run_case 1 '/etc/passwd'
  run_case 1 '/var/log/auth.log'
  run_case 1 '/usr/bin/ls'
  run_case 1 "$HOME/.ssh/id_rsa"
  run_case 1 "$HOME/.aws/credentials"
}

cell_credential_json() {
  # PR 7 of the 2026-05-10 architecture audit: credential
  # JSON basenames must block at write time the same way they
  # block at read time. The shapes here mirror the G-035
  # read-guard rule in guard/rules.json.
  run_case 1 'credentials.json'
  run_case 1 'credential.json'
  run_case 1 'secrets.json'
  run_case 1 'secret.json'
  run_case 1 'service-account.json'
  run_case 1 'service_account.json'
  run_case 1 'service-account-prod.json'
  run_case 1 'firebase-adminsdk.json'
  run_case 1 'firebase-adminsdk-staging.json'
  run_case 1 'google-credentials.json'
  run_case 1 'gcp-credentials.json'
  run_case 1 'aws-credentials.json'
  run_case 1 'aws-credentials-prod.json'
  run_case 1 'supabase-service-role.json'
  run_case 1 'client-secrets.json'
  run_case 1 'client_secret.json'
  # Separator-less credential JSON variants. Codex caught
  # the missing optional separator on the PR 7 first review
  # pass: G-035 read-side allows [-_]? but the initial
  # write patterns required the separator.
  run_case 1 'serviceaccount.json'
  run_case 1 'firebaseadminsdk.json'
  run_case 1 'googlecredentials.json'
  run_case 1 'clientsecret.json'
  run_case 1 'awscredentials.json'
  run_case 1 'gcpcredentials.json'
  # Suffixed generic credential / secret JSON. Codex caught
  # the missing suffix support on the PR 7 second review
  # pass: G-035 read-side blocks credentials-prod.json and
  # secrets-backup.json; the write side now does too.
  run_case 1 'credentials-prod.json'
  run_case 1 'credential-staging.json'
  run_case 1 'secret-prod.json'
  run_case 1 'secrets-backup.json'
  run_case 1 'credentials.dev.json'
  # Mixed-case credential JSON. Codex caught the case gap on
  # the PR 7 third review pass: read-side G-035 is case-
  # insensitive, so the write side must match too.
  run_case 1 'Credentials.json'
  run_case 1 'Service-Account.json'
  run_case 1 'AWS-Credentials.json'
  run_case 1 'Firebase-Adminsdk.json'
  run_case 1 'SECRETS.json'
  run_case 1 '.ENV'
  # Mixed-case templates stay allowed.
  run_case 0 'credentials.Example.json'
  run_case 0 'Service-Account.Template.json'
  # Protected directories still block even when the leaf has
  # a template-looking basename. Codex caught the over-broad
  # template exemption on the PR 7 first review pass:
  # $HOME/.ssh/config.example must not become a bypass.
  run_case 1 "$HOME/.ssh/config.example"
  run_case 1 "$HOME/.ssh/config.template"
  run_case 1 "/etc/foo.template"
  run_case 1 "/etc/foo.sample"
}

cell_templates_and_project() {
  # Allowed: templates + regular project files. Template
  # basenames (.example, .sample, .template, with or without
  # extension) MUST pass even when the rest of the name looks
  # like a secret, otherwise first-run onboarding fights the
  # guard.
  run_case 0 '.env.example'
  run_case 0 '.env.sample'
  run_case 0 '.env.template'
  run_case 0 'credentials.example.json'
  run_case 0 'service-account.example.json'
  run_case 0 'service-account.template.json'
  run_case 0 'firebase-adminsdk.sample.json'
  run_case 0 'README.md'
  run_case 0 'src/config.js'
  run_case 0 'package.json'
  run_case 0 'firebase.json'
  run_case 0 'tsconfig.json'
  run_case 0 '/tmp/scratch.txt'
}

cell_stdin_json() {
  # JSON input path (Claude Code PreToolUse contract).
  if echo '{"tool_name":"Write","tool_input":{"file_path":".env"}}' \
    | bash "$CHECK_WRITE" >/dev/null 2>&1; then
    nh_fail "stdin-json .env" "JSON stdin did not block .env"
  else
    nh_pass "stdin-json blocks .env"
  fi
  if echo '{"tool_name":"Edit","tool_input":{"file_path":"README.md"}}' \
    | bash "$CHECK_WRITE" >/dev/null 2>&1; then
    nh_pass "stdin-json allows README.md"
  else
    nh_fail "stdin-json README.md" "JSON stdin did not allow README.md"
  fi
}

cell_symlinks() {
  # Symlink resolution: a symlink whose target is a protected path must
  # be blocked even when the textual path does not match the denylist.
  local link_dir="$WORK/symlink-test"
  mkdir -p "$link_dir"
  ln -sfn /etc "$link_dir/etclink"
  if bash "$CHECK_WRITE" "$link_dir/etclink/passwd" >/dev/null 2>&1; then
    nh_fail "symlink etclink/passwd" "symlink to /etc bypassed denylist"
  else
    nh_pass "symlink etclink/passwd blocks (resolves to /etc)"
  fi
  # And a symlink that does NOT point at a protected target stays
  # allowed (regression: do not over-block legitimate symlinks).
  ln -sfn "$WORK" "$link_dir/safelink"
  if bash "$CHECK_WRITE" "$link_dir/safelink/notes.txt" >/dev/null 2>&1; then
    nh_pass "symlink to safe target allows"
  else
    nh_fail "symlink safelink/notes.txt" "symlink to safe target was blocked"
  fi
}

nh_cell secrets-and-system cell_secrets_and_system
nh_cell credential-json cell_credential_json
nh_cell templates-and-project cell_templates_and_project
nh_cell stdin-json cell_stdin_json
nh_cell symlinks cell_symlinks

nh_summary
