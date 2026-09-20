#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROVENANCE_COMMIT="${INDIEBUILD_PROVENANCE_COMMIT:-5cfac43c6900898f36f588d044ca34083da1c726}"
WORKER_SHA="${INDIEBUILD_WORKER_SHA:?INDIEBUILD_WORKER_SHA is required}"
WORK_ROOT="$ROOT/.ores/ci-worker-source"
K8S_ROOT="$WORK_ROOT/k8s-cluster"
WORKER_ROOT="$K8S_ROOT/remote/deployments/build-server-rs"
TARGET_ROOT="$ROOT/.ores/ci-worker-target"

is_oid() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

if ! is_oid "$PROVENANCE_COMMIT" || ! is_oid "$WORKER_SHA"; then
  echo "provenance and worker revisions must be full lowercase 40-character Git OIDs" >&2
  exit 2
fi

mkdir -p "$WORK_ROOT" "$TARGET_ROOT"

if [[ ! -d "$K8S_ROOT/.git" ]]; then
  rm -rf "$K8S_ROOT"
  git clone --filter=blob:none --no-checkout https://github.com/ORESoftware/k8s-cluster.git "$K8S_ROOT"
fi

git -C "$K8S_ROOT" fetch --depth=1 origin "$PROVENANCE_COMMIT"
git -C "$K8S_ROOT" checkout --detach --force "$PROVENANCE_COMMIT"

# The split worker is the only subtree replaced. Sibling `remote/libs/*` stay
# byte-for-byte from SOURCE_PROVENANCE.md's immutable k8s-cluster commit so the
# split repository retains its original path-dependency build context.
rm -rf "$WORKER_ROOT"
git clone --filter=blob:none --no-checkout https://github.com/gha-indie-worker/gha-indie-worker.rs.git "$WORKER_ROOT"
git -C "$WORKER_ROOT" fetch --depth=1 origin "$WORKER_SHA"
git -C "$WORKER_ROOT" checkout --detach --force "$WORKER_SHA"

actual_worker_sha="$(git -C "$WORKER_ROOT" rev-parse HEAD)"
if [[ "$actual_worker_sha" != "$WORKER_SHA" ]]; then
  echo "worker checkout drifted: expected $WORKER_SHA, got $actual_worker_sha" >&2
  exit 3
fi

grep -Fq "$PROVENANCE_COMMIT" "$WORKER_ROOT/SOURCE_PROVENANCE.md" || {
  echo "worker provenance does not bind the requested k8s-cluster commit" >&2
  exit 4
}

test -f "$K8S_ROOT/remote/libs/telemetry-rs/Cargo.toml"
test -f "$K8S_ROOT/remote/libs/runtime-config-client-rs/Cargo.toml"
test -f "$K8S_ROOT/remote/libs/nats/subject-defs/generated/rust/Cargo.toml"

CARGO_TARGET_DIR="$TARGET_ROOT" cargo build \
  --locked \
  --manifest-path "$WORKER_ROOT/Cargo.toml" \
  --bin dd-build-server

test -x "$TARGET_ROOT/debug/dd-build-server"
printf 'worker=%s\nprovenance=%s\nbinary=%s\n' \
  "$WORKER_SHA" "$PROVENANCE_COMMIT" "$TARGET_ROOT/debug/dd-build-server"
