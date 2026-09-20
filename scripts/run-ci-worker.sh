#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/.ores/ci-worker-target/debug/dd-build-server"

require_nonempty() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    echo "ci-worker startup refused: $key is missing or empty" >&2
    exit 40
  fi
}

require_nonempty BUILD_SERVER_WORK_ROOT
require_nonempty BUILD_SERVER_GITHUB_APP_ID
require_nonempty BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH
require_nonempty BUILD_SERVER_GITHUB_WEBHOOK_SECRET
require_nonempty BUILD_SERVER_AUTH_SECRET

case "$BUILD_SERVER_WORK_ROOT" in
  /*) ;;
  *)
    echo "ci-worker startup refused: BUILD_SERVER_WORK_ROOT must be an absolute operator-owned path" >&2
    exit 41
    ;;
esac

case "$BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH" in
  /*) ;;
  *)
    echo "ci-worker startup refused: BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH must be absolute" >&2
    exit 42
    ;;
esac

if [[ ! -r "$BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH" || ! -f "$BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH" ]]; then
  echo "ci-worker startup refused: GitHub App private key path is not a readable regular file" >&2
  exit 43
fi

mkdir -p "$BUILD_SERVER_WORK_ROOT"
canonical_work_root="$(cd "$BUILD_SERVER_WORK_ROOT" && pwd -P)"
case "$canonical_work_root" in
  "$ROOT"|"$ROOT"/*)
    echo "ci-worker startup refused: durable work root must live outside the materialized monorepo source" >&2
    exit 44
    ;;
esac
export BUILD_SERVER_WORK_ROOT="$canonical_work_root"

if [[ ! -x "$BIN" ]]; then
  echo "ci-worker startup refused: pinned worker binary is missing; run scripts/bootstrap-ci-worker.sh first" >&2
  exit 45
fi

exec "$BIN"
