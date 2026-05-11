#!/usr/bin/env bash
# artifact-trust.sh — Shared trust primitive for nanostack artifacts.
#
# Single source of truth for "can I trust this artifact?" Used by
# find-artifact.sh (--require-integrity), resolve.sh (upstream_status),
# and downstream skills that build release gates or compose evidence.
#
# Before this library existed, each caller wrote its own jq + sha256
# dance. release-readiness in particular grew a local check for
# missing .integrity because find-artifact.sh --verify only failed on
# mismatch, not absence. The 2026-05-10 architecture audit (PR 2)
# moves that logic here so every layer agrees on the trust model.
#
# Public function:
#   nano_artifact_trust <path>
#     Echoes one of: verified, integrity_missing, integrity_mismatch,
#     not_found. Always exits 0 on a regular file (status is on
#     stdout); exits 1 only when the path is empty or does not exist.
#
# Statuses:
#   verified           - file is a regular JSON file, .integrity is
#                        present, and the recomputed SHA-256 over the
#                        canonical (sorted, no-integrity) JSON matches.
#   integrity_missing  - file is a regular JSON file, but the
#                        .integrity field is absent or empty. An
#                        attacker who can write the file can delete
#                        the field as easily as mutate the hash, so
#                        release gates treat this as untrusted.
#   integrity_mismatch - file is a regular JSON file, .integrity is
#                        present, and the recomputed hash does not
#                        match. The artifact was modified after
#                        save-artifact.sh wrote it.
#   not_found          - path is empty, does not exist, or is not a
#                        regular file. Exit code 1.

if [ "${_NANO_ARTIFACT_TRUST_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_NANO_ARTIFACT_TRUST_LOADED=1

# Recompute the canonical SHA-256 over a JSON artifact. Strips
# .integrity (the field is added after the hash is computed), sorts
# keys for stability, and emits the bare hex digest. Mirrors
# save-artifact.sh's hashing path so a freshly saved artifact
# verifies on first read.
_nano_artifact_recompute_hash() {
  local path="$1"
  local hash_cmd
  if declare -F nano_sha256 >/dev/null 2>&1; then
    hash_cmd="nano_sha256"
  elif command -v shasum >/dev/null 2>&1; then
    hash_cmd="shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash_cmd="sha256sum"
  else
    return 1
  fi
  jq -Sc 'del(.integrity)' "$path" 2>/dev/null \
    | eval "$hash_cmd" 2>/dev/null \
    | cut -d' ' -f1
}

nano_artifact_trust() {
  local path="${1:-}"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    printf 'not_found\n'
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    # No jq means we cannot inspect the integrity field at all. Treat
    # as missing so callers under strict mode fail closed.
    printf 'integrity_missing\n'
    return 0
  fi
  local stored
  stored=$(jq -r '.integrity // ""' "$path" 2>/dev/null)
  if [ -z "$stored" ]; then
    printf 'integrity_missing\n'
    return 0
  fi
  local computed
  computed=$(_nano_artifact_recompute_hash "$path")
  if [ -z "$computed" ] || [ "$computed" != "$stored" ]; then
    printf 'integrity_mismatch\n'
    return 0
  fi
  printf 'verified\n'
  return 0
}
