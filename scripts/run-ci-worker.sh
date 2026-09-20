#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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

receipt_value() {
  local key="$1"
  awk -F= -v wanted="$key" '
    $1 == wanted { count += 1; value = substr($0, length(wanted) + 2) }
    END { if (count != 1) exit 2; print value }
  ' "$RECEIPT"
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    env -i HOME="$HOME" PATH="$PATH" sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    env -i HOME="$HOME" PATH="$PATH" shasum -a 256 "$1" | awk '{print $1}'
  else
    refuse "sha256sum or shasum is required to verify the pinned worker binary"
  fi
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

[[ "$BUILD_SERVER_GITHUB_APP_ID" =~ ^[1-9][0-9]*$ ]] || refuse "BUILD_SERVER_GITHUB_APP_ID must be a positive decimal App id"
is_oid "$INDIEBUILD_WORKER_SHA" || refuse "INDIEBUILD_WORKER_SHA must be a full lowercase 40-character Git OID"
is_oid "$INDIEBUILD_PROVENANCE_COMMIT" || refuse "INDIEBUILD_PROVENANCE_COMMIT must be a full lowercase 40-character Git OID"
(( ${#BUILD_SERVER_GITHUB_WEBHOOK_SECRET} >= 32 )) || refuse "GitHub webhook secret is too short"
(( ${#BUILD_SERVER_AUTH_SECRET} >= 32 )) || refuse "worker auth secret is too short"

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

case "$BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH" in
  /*) ;;
  *) refuse "BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH must be absolute" ;;
esac
[[ ! -L "$BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH" ]] || refuse "GitHub App private key path must not be a symlink"
if [[ ! -r "$BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH" || ! -f "$BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH" ]]; then
  refuse "GitHub App private key path is not a readable regular file"
fi
key_dir="$(cd "$(dirname "$BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH")" && pwd -P)"
canonical_key_path="$key_dir/$(basename "$BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH")"
export BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH="$canonical_key_path"

[[ ! -L "$BIN" && -x "$BIN" ]] || refuse "pinned worker binary is missing, symlinked, or not executable; run scripts/bootstrap-ci-worker.sh first"
[[ ! -L "$RECEIPT" && -f "$RECEIPT" && -r "$RECEIPT" ]] || refuse "worker provenance receipt is missing, symlinked, or unreadable"

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

exec "$BIN"
