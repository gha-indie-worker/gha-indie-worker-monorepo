#!/usr/bin/env bash
set -euo pipefail
umask 077

script_path="${BASH_SOURCE[0]}"
script_dir="${script_path%/*}"
[[ "$script_dir" != "$script_path" ]] || script_dir="."
ROOT="$(cd "$script_dir/.." && pwd -P)"
TARGET_ROOT="$ROOT/.ores/ci-worker-target"
BIN="$TARGET_ROOT/debug/dd-build-server"
RECEIPT="$TARGET_ROOT/provenance.receipt"

refuse() {
  echo "ci-worker startup refused: $*" >&2
  exit 40
}

require_nonempty() {
  local key="$1"
  [[ -n "${!key:-}" ]] || refuse "$key is missing or empty"
}

is_oid() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

for key in \
  BUILD_SERVER_WORK_ROOT \
  BUILD_SERVER_GITHUB_APP_ID \
  BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH \
  BUILD_SERVER_GITHUB_WEBHOOK_SECRET \
  BUILD_SERVER_AUTH_SECRET \
  INDIEBUILD_WORKER_SHA \
  INDIEBUILD_PROVENANCE_COMMIT; do
  require_nonempty "$key"
done

# Capture secret-bearing bindings as ordinary non-exported shell variables, then
# remove them from the process environment before invoking any helper binary.
# They are restored only for the final exec of dd-build-server.
app_key_path_input="$BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH"
webhook_secret="$BUILD_SERVER_GITHUB_WEBHOOK_SECRET"
worker_auth_secret="$BUILD_SERVER_AUTH_SECRET"
unset BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH
unset BUILD_SERVER_GITHUB_WEBHOOK_SECRET
unset BUILD_SERVER_AUTH_SECRET

[[ "$BUILD_SERVER_GITHUB_APP_ID" =~ ^[1-9][0-9]*$ ]] || refuse "BUILD_SERVER_GITHUB_APP_ID must be a positive decimal App id"
is_oid "$INDIEBUILD_WORKER_SHA" || refuse "INDIEBUILD_WORKER_SHA must be a full lowercase 40-character Git OID"
is_oid "$INDIEBUILD_PROVENANCE_COMMIT" || refuse "INDIEBUILD_PROVENANCE_COMMIT must be a full lowercase 40-character Git OID"
(( ${#webhook_secret} >= 32 )) || refuse "GitHub webhook secret is too short"
(( ${#worker_auth_secret} >= 32 )) || refuse "worker auth secret is too short"

case "$BUILD_SERVER_WORK_ROOT" in
  /*) ;;
  *) refuse "BUILD_SERVER_WORK_ROOT must be an absolute operator-owned path" ;;
esac
[[ "$BUILD_SERVER_WORK_ROOT" != "/" ]] || refuse "BUILD_SERVER_WORK_ROOT may not be filesystem root"
[[ ! -L "$BUILD_SERVER_WORK_ROOT" ]] || refuse "BUILD_SERVER_WORK_ROOT must not be a symlink"
mkdir -p "$BUILD_SERVER_WORK_ROOT"
chmod 700 "$BUILD_SERVER_WORK_ROOT"
canonical_work_root="$(cd "$BUILD_SERVER_WORK_ROOT" && pwd -P)"
case "$canonical_work_root" in
  "$ROOT"|"$ROOT"/*) refuse "durable work root must live outside the materialized monorepo source" ;;
esac
export BUILD_SERVER_WORK_ROOT="$canonical_work_root"

case "$app_key_path_input" in
  /*) ;;
  *) refuse "BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH must be absolute" ;;
esac
[[ ! -L "$app_key_path_input" ]] || refuse "GitHub App private key path must not be a symlink"
if [[ ! -r "$app_key_path_input" || ! -f "$app_key_path_input" ]]; then
  refuse "GitHub App private key path is not a readable regular file"
fi
key_dir_input="${app_key_path_input%/*}"
key_basename="${app_key_path_input##*/}"
[[ -n "$key_dir_input" && -n "$key_basename" ]] || refuse "GitHub App private key path is malformed"
canonical_key_dir="$(cd "$key_dir_input" && pwd -P)"
canonical_key_path="$canonical_key_dir/$key_basename"
[[ ! -L "$canonical_key_path" && -r "$canonical_key_path" && -f "$canonical_key_path" ]] || refuse "canonical GitHub App private key is not a readable regular file"

[[ ! -L "$BIN" && -x "$BIN" ]] || refuse "pinned worker binary is missing, symlinked, or not executable; run scripts/bootstrap-ci-worker.sh first"
[[ ! -L "$RECEIPT" && -f "$RECEIPT" && -r "$RECEIPT" ]] || refuse "worker provenance receipt is missing, symlinked, or unreadable"

receipt_value() {
  local wanted="$1"
  local key value found=0 result=""
  while IFS='=' read -r key value; do
    if [[ "$key" == "$wanted" ]]; then
      found=$((found + 1))
      result="$value"
    fi
  done <"$RECEIPT"
  [[ "$found" -eq 1 ]] || return 2
  printf '%s\n' "$result"
}

hash_file() {
  local output hash
  if command -v sha256sum >/dev/null 2>&1; then
    output="$(sha256sum "$1")"
  elif command -v shasum >/dev/null 2>&1; then
    output="$(shasum -a 256 "$1")"
  else
    refuse "sha256sum or shasum is required to verify the pinned worker binary"
  fi
  hash="${output%% *}"
  printf '%s\n' "$hash"
}

receipt_schema="$(receipt_value schema)" || refuse "invalid worker provenance receipt schema field"
receipt_worker="$(receipt_value worker_sha)" || refuse "invalid worker provenance receipt worker field"
receipt_provenance="$(receipt_value provenance_sha)" || refuse "invalid worker provenance receipt provenance field"
receipt_binary="$(receipt_value binary_sha256)" || refuse "invalid worker provenance receipt binary field"
[[ "$receipt_schema" == "indiebuild.worker-provenance.v1" ]] || refuse "unknown worker provenance receipt schema"
[[ "$receipt_worker" == "$INDIEBUILD_WORKER_SHA" ]] || refuse "built worker SHA does not match operator pin"
[[ "$receipt_provenance" == "$INDIEBUILD_PROVENANCE_COMMIT" ]] || refuse "built provenance SHA does not match operator pin"
[[ "$receipt_binary" =~ ^[0-9a-f]{64}$ ]] || refuse "receipt contains an invalid worker binary hash"
actual_binary="$(hash_file "$BIN")"
[[ "$actual_binary" == "$receipt_binary" ]] || refuse "worker binary hash does not match its provenance receipt"

export BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH="$canonical_key_path"
export BUILD_SERVER_GITHUB_WEBHOOK_SECRET="$webhook_secret"
export BUILD_SERVER_AUTH_SECRET="$worker_auth_secret"
exec "$BIN"
