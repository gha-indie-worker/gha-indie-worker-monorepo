#!/usr/bin/env bash
set -euo pipefail
umask 077

script_path="${BASH_SOURCE[0]}"
script_dir="${script_path%/*}"
[[ "$script_dir" != "$script_path" ]] || script_dir="."
ROOT="$(cd "$script_dir/.." && pwd -P)"
PROVENANCE_COMMIT="${INDIEBUILD_PROVENANCE_COMMIT:-5cfac43c6900898f36f588d044ca34083da1c726}"
WORKER_SHA="${INDIEBUILD_WORKER_SHA:?INDIEBUILD_WORKER_SHA is required}"
CLEAN_HOME="${HOME:?HOME is required}"
CLEAN_PATH="${PATH:?PATH is required}"
CLEAN_RUSTUP_HOME="${RUSTUP_HOME:-}"

# This script runs as the ci-worker *build* command. ores-compose deliberately
# admits the service environment before every phase, so scrub the current shell
# before invoking even trusted helper binaries. The build needs only filesystem,
# public HTTPS, Cargo/Rust and the two immutable revisions captured above.
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
WORKER_ROOT="$K8S_ROOT/remote/deployments/build-server-rs"
TARGET_ROOT="$ORES_ROOT/ci-worker-target"
CARGO_HOME_CLEAN="$ORES_ROOT/cargo-home"
RECEIPT="$TARGET_ROOT/provenance.receipt"
K8S_ORIGIN="https://github.com/ORESoftware/k8s-cluster.git"
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

require_real_directory_or_absent "$ORES_ROOT" ".ores runtime root"
require_real_directory_or_absent "$WORK_ROOT" "worker source root"
require_real_directory_or_absent "$TARGET_ROOT" "worker target root"
mkdir -p "$WORK_ROOT" "$TARGET_ROOT" "$CARGO_HOME_CLEAN"
chmod 700 "$ORES_ROOT" "$WORK_ROOT" "$TARGET_ROOT" "$CARGO_HOME_CLEAN"

# Defense in depth: every Git/Cargo process also starts from a fresh environment.
# Global/system Git config is disabled so url.*.insteadOf, credential helpers,
# hooks and protocol policy cannot silently rewrite the reviewed HTTPS origins.
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

# The split worker is the only subtree replaced. Sibling `remote/libs/*` stay
# byte-for-byte from SOURCE_PROVENANCE.md's immutable k8s-cluster commit so the
# split repository retains its original path-dependency build context.
rm -rf "$WORKER_ROOT"
git_clean clone --filter=blob:none --no-checkout "$WORKER_ORIGIN" "$WORKER_ROOT"
git_clean -C "$WORKER_ROOT" fetch --depth=1 origin "$WORKER_SHA"
git_clean -C "$WORKER_ROOT" checkout --detach --force "$WORKER_SHA"
actual_worker_sha="$(git_clean -C "$WORKER_ROOT" rev-parse HEAD)"
[[ "$actual_worker_sha" == "$WORKER_SHA" ]] || fail "worker checkout drifted"
actual_worker_origin="$(git_clean -C "$WORKER_ROOT" remote get-url origin)"
[[ "$actual_worker_origin" == "$WORKER_ORIGIN" ]] || fail "worker origin is not the reviewed repository"

grep -Fq "$PROVENANCE_COMMIT" "$WORKER_ROOT/SOURCE_PROVENANCE.md" || \
  fail "worker provenance does not bind the requested k8s-cluster commit"

test -f "$K8S_ROOT/remote/libs/telemetry-rs/Cargo.toml" || fail "telemetry-rs provenance dependency missing"
test -f "$K8S_ROOT/remote/libs/runtime-config-client-rs/Cargo.toml" || fail "runtime-config-client-rs provenance dependency missing"
test -f "$K8S_ROOT/remote/libs/nats/subject-defs/generated/rust/Cargo.toml" || fail "NATS subject provenance dependency missing"

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
printf 'schema=indiebuild.worker-provenance.v1\nworker_sha=%s\nprovenance_sha=%s\nbinary_sha256=%s\n' \
  "$WORKER_SHA" "$PROVENANCE_COMMIT" "$binary_sha256" >"$receipt_tmp"
chmod 600 "$receipt_tmp"
mv -f "$receipt_tmp" "$RECEIPT"

printf 'worker=%s\nprovenance=%s\nbinary_sha256=%s\nbinary=%s\nreceipt=%s\n' \
  "$WORKER_SHA" "$PROVENANCE_COMMIT" "$binary_sha256" "$BIN" "$RECEIPT"
