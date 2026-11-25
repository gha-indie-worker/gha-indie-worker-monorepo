#!/usr/bin/env bash
set -euo pipefail
umask 077

script_path="${BASH_SOURCE[0]}"
script_dir="${script_path%/*}"
[[ "$script_dir" != "$script_path" ]] || script_dir="."
ROOT="$(cd "$script_dir/.." && pwd -P)"
PROVENANCE_COMMIT="${INDIEBUILD_PROVENANCE_COMMIT:-5cfac43c6900898f36f588d044ca34083da1c726}"
WORKER_SHA="${INDIEBUILD_WORKER_SHA:?INDIEBUILD_WORKER_SHA is required}"
LIBS_SOURCE_DIR="${INDIEBUILD_LIBS_SOURCE_DIR:-}"
CLEAN_HOME="${HOME:?HOME is required}"
CLEAN_PATH="${PATH:?PATH is required}"
CLEAN_RUSTUP_HOME="${RUSTUP_HOME:-}"

# This script runs as the ci-worker *build* command. ores-compose deliberately
# admits the service environment before every phase, so scrub the current shell
# before invoking even trusted helper binaries. The build needs only filesystem,
# public HTTPS, Cargo/Rust and immutable source coordinates captured above.
for exported_name in $(compgen -e); do
  case "$exported_name" in
    HOME|PATH|RUSTUP_HOME) ;;
    *) unset "$exported_name" ;;
  esac
done
export HOME="$CLEAN_HOME" PATH="$CLEAN_PATH"
if [[ -n "$CLEAN_RUSTUP_HOME" ]]; then
  export RUSTUP_HOME="$CLEAN_RUSTUP_HOME"
else
  unset RUSTUP_HOME || true
fi

ORES_ROOT="$ROOT/.ores"
WORK_ROOT="$ORES_ROOT/ci-worker-source"
K8S_ROOT="$WORK_ROOT/k8s-cluster"
LIBS_ROOT="$K8S_ROOT/remote/libs"
WORKER_ROOT="$K8S_ROOT/remote/deployments/build-server-rs"
TARGET_ROOT="$ORES_ROOT/ci-worker-target"
CARGO_HOME_CLEAN="$ORES_ROOT/cargo-home"
RECEIPT="$TARGET_ROOT/provenance.receipt"
K8S_ORIGIN="https://github.com/ORESoftware/k8s-cluster.git"
LIBS_ORIGIN="https://github.com/ORESoftware/k8s-libs-and-shared-defs.git"
WORKER_ORIGIN="https://github.com/gha-indie-worker/gha-indie-worker.rs.git"

fail() {
  echo "ci-worker bootstrap refused: $*" >&2
  exit 2
}

is_oid() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

require_real_directory_or_absent() {
  local path="$1"
  local label="$2"
  if [[ -L "$path" ]]; then
    fail "$label must not be a symlink"
  fi
  if [[ -e "$path" && ! -d "$path" ]]; then
    fail "$label must be a directory"
  fi
}

if ! is_oid "$PROVENANCE_COMMIT" || ! is_oid "$WORKER_SHA"; then
  fail "provenance and worker revisions must be full lowercase 40-character Git OIDs"
fi
case "$LIBS_SOURCE_DIR" in
  /*) ;;
  "") fail "INDIEBUILD_LIBS_SOURCE_DIR is required for the private provenance gitlink" ;;
  *) fail "INDIEBUILD_LIBS_SOURCE_DIR must be an absolute operator-owned checkout path" ;;
esac
[[ ! -L "$LIBS_SOURCE_DIR" ]] || fail "private provenance source must not be a symlink"
[[ -d "$LIBS_SOURCE_DIR/.git" && ! -L "$LIBS_SOURCE_DIR/.git" ]] || \
  fail "private provenance source must be a normal Git checkout"
canonical_libs_source="$(cd "$LIBS_SOURCE_DIR" && pwd -P)"
case "$canonical_libs_source" in
  "$ROOT"|"$ROOT"/*) fail "private provenance source must live outside the materialized monorepo" ;;
esac

require_real_directory_or_absent "$ORES_ROOT" ".ores runtime root"
require_real_directory_or_absent "$WORK_ROOT" "worker source root"
require_real_directory_or_absent "$TARGET_ROOT" "worker target root"
mkdir -p "$WORK_ROOT" "$TARGET_ROOT" "$CARGO_HOME_CLEAN"
chmod 700 "$ORES_ROOT" "$WORK_ROOT" "$TARGET_ROOT" "$CARGO_HOME_CLEAN"

# Defense in depth: every Git/Cargo/helper process also starts from a fresh
# environment. Global/system Git config is disabled so url.*.insteadOf,
# credential helpers, hooks and protocol policy cannot rewrite reviewed origins.
CLEAN_ENV=(
  env -i
  "HOME=$CLEAN_HOME"
  "PATH=$CLEAN_PATH"
  "GIT_CONFIG_NOSYSTEM=1"
  "GIT_CONFIG_GLOBAL=/dev/null"
  "GIT_TERMINAL_PROMPT=0"
  "GIT_ASKPASS=/bin/false"
  "CARGO_HOME=$CARGO_HOME_CLEAN"
)
if [[ -n "$CLEAN_RUSTUP_HOME" ]]; then
  CLEAN_ENV+=("RUSTUP_HOME=$CLEAN_RUSTUP_HOME")
fi

git_clean() {
  "${CLEAN_ENV[@]}" git \
    -c protocol.file.allow=never \
    -c protocol.ext.allow=never \
    -c protocol.ssh.allow=never \
    -c protocol.git.allow=never \
    -c protocol.https.allow=always \
    "$@"
}

clone_exact_https() {
  local origin="$1"
  local oid="$2"
  local dest="$3"
  local label="$4"

  is_oid "$oid" || fail "$label revision is not a full lowercase Git OID"
  rm -rf "$dest"
  git_clean clone --filter=blob:none --no-checkout "$origin" "$dest"
  git_clean -C "$dest" fetch --depth=1 origin "$oid"
  git_clean -C "$dest" checkout --detach --force "$oid"

  local actual_oid actual_origin
  actual_oid="$(git_clean -C "$dest" rev-parse HEAD)"
  actual_origin="$(git_clean -C "$dest" remote get-url origin)"
  [[ "$actual_oid" == "$oid" ]] || fail "$label checkout drifted"
  [[ "$actual_origin" == "$origin" ]] || fail "$label origin is not the reviewed HTTPS repository"
}

materialize_private_gitlink() {
  local source="$1"
  local oid="$2"
  local dest="$3"

  is_oid "$oid" || fail "private provenance gitlink is not a full lowercase Git OID"
  local actual_oid actual_origin
  actual_oid="$(git_clean -C "$source" rev-parse HEAD)"
  actual_origin="$(git_clean -C "$source" remote get-url origin)"
  [[ "$actual_oid" == "$oid" ]] || \
    fail "private provenance checkout HEAD $actual_oid does not match gitlink $oid"
  [[ "$actual_origin" == "$LIBS_ORIGIN" ]] || \
    fail "private provenance checkout origin is not the reviewed HTTPS repository"

  rm -rf "$dest"
  mkdir -p "$dest"
  # Archive the committed tree, never the operator checkout's mutable working
  # tree. The private checkout path and any credentials used to prepare it stay
  # outside this build environment and are not passed to tar/Cargo.
  git_clean -C "$source" archive --format=tar "$oid" | \
    "${CLEAN_ENV[@]}" tar -xf - -C "$dest"
}

if [[ -L "$K8S_ROOT" || -L "$K8S_ROOT/.git" ]]; then
  fail "cached provenance checkout must not be symlinked"
fi
if [[ -e "$K8S_ROOT" && ! -d "$K8S_ROOT/.git" ]]; then
  fail "cached provenance checkout is not a normal Git repository"
fi

if [[ ! -d "$K8S_ROOT/.git" ]]; then
  rm -rf "$K8S_ROOT"
  git_clean clone --filter=blob:none --no-checkout "$K8S_ORIGIN" "$K8S_ROOT"
else
  actual_origin="$(git_clean -C "$K8S_ROOT" remote get-url origin)"
  [[ "$actual_origin" == "$K8S_ORIGIN" ]] || fail "cached provenance origin is not the reviewed repository"
fi

git_clean -C "$K8S_ROOT" fetch --depth=1 origin "$PROVENANCE_COMMIT"
git_clean -C "$K8S_ROOT" checkout --detach --force "$PROVENANCE_COMMIT"
git_clean -C "$K8S_ROOT" reset --hard "$PROVENANCE_COMMIT"
# checkout --force does not remove attacker/stale untracked files. Remove them
# before Cargo is allowed to observe sibling path dependencies.
git_clean -C "$K8S_ROOT" clean -ffdqx
actual_provenance_sha="$(git_clean -C "$K8S_ROOT" rev-parse HEAD)"
[[ "$actual_provenance_sha" == "$PROVENANCE_COMMIT" ]] || fail "provenance checkout drifted"

# `remote/libs` is a private gitlink in k8s-cluster. Do not use recursive
# submodules or inject a cross-repo token into this build shell. Read the exact
# gitlink OID from the immutable provenance tree, verify an operator-prepared
# checkout outside this source tree, and archive only that exact committed tree.
libs_tree="$(git_clean -C "$K8S_ROOT" ls-tree "$PROVENANCE_COMMIT" -- remote/libs)"
read -r libs_mode libs_type libs_sha libs_path <<<"$libs_tree"
[[ "$libs_mode" == "160000" && "$libs_type" == "commit" && "$libs_path" == "remote/libs" ]] || \
  fail "provenance remote/libs entry is not the expected gitlink"
materialize_private_gitlink "$canonical_libs_source" "$libs_sha" "$LIBS_ROOT"

# The split worker is the only deployment subtree replaced. Its sibling path
# dependencies come from the exact `remote/libs` gitlink recorded by the same
# immutable k8s-cluster provenance commit.
clone_exact_https "$WORKER_ORIGIN" "$WORKER_SHA" "$WORKER_ROOT" "worker"

grep -Fq "$PROVENANCE_COMMIT" "$WORKER_ROOT/SOURCE_PROVENANCE.md" || \
  fail "worker provenance does not bind the requested k8s-cluster commit"

test -f "$LIBS_ROOT/telemetry-rs/Cargo.toml" || fail "telemetry-rs provenance dependency missing"
test -f "$LIBS_ROOT/runtime-config-client-rs/Cargo.toml" || fail "runtime-config-client-rs provenance dependency missing"
test -f "$LIBS_ROOT/nats/subject-defs/generated/rust/Cargo.toml" || fail "NATS subject provenance dependency missing"

"${CLEAN_ENV[@]}" \
  CARGO_TARGET_DIR="$TARGET_ROOT" \
  cargo build \
    --locked \
    --manifest-path "$WORKER_ROOT/Cargo.toml" \
    --bin dd-build-server

BIN="$TARGET_ROOT/debug/dd-build-server"
test -x "$BIN" || fail "expected worker binary was not produced"

hash_file() {
  local output hash
  if command -v sha256sum >/dev/null 2>&1; then
    output="$("${CLEAN_ENV[@]}" sha256sum "$1")"
  elif command -v shasum >/dev/null 2>&1; then
    output="$("${CLEAN_ENV[@]}" shasum -a 256 "$1")"
  else
    fail "sha256sum or shasum is required to bind the built worker binary"
  fi
  hash="${output%% *}"
  printf '%s\n' "$hash"
}

binary_sha256="$(hash_file "$BIN")"
[[ "$binary_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "could not compute worker binary SHA-256"
receipt_tmp="$RECEIPT.tmp.$$"
printf 'schema=indiebuild.worker-provenance.v1\nworker_sha=%s\nprovenance_sha=%s\nlibs_sha=%s\nbinary_sha256=%s\n' \
  "$WORKER_SHA" "$PROVENANCE_COMMIT" "$libs_sha" "$binary_sha256" >"$receipt_tmp"
chmod 600 "$receipt_tmp"
mv -f "$receipt_tmp" "$RECEIPT"

printf 'worker=%s\nprovenance=%s\nlibs=%s\nbinary_sha256=%s\nbinary=%s\nreceipt=%s\n' \
  "$WORKER_SHA" "$PROVENANCE_COMMIT" "$libs_sha" "$binary_sha256" "$BIN" "$RECEIPT"
