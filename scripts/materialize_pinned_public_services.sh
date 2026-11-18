#!/usr/bin/env bash
# Materialize only the two reviewed, public, exact Gitlinks from HEAD.
# No admin token, moving branch, cross-org mirror, or private-source checkout.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

services=(
  apps/gha-indie-worker-api-server.rs
  apps/gha-indie-worker-web-server.rs
)
mapfile -t gitlink_paths < <(git ls-tree -r HEAD | awk '$1 == "160000" && $2 == "commit" {print $4}')
if [[ "${#gitlink_paths[@]}" -ne "${#services[@]}" ]]; then
  echo "FAIL: expected exactly two public service Gitlinks" >&2
  exit 1
fi

for path in "${services[@]}"; do
  case "$path" in
    apps/gha-indie-worker-api-server.rs)
      url="https://github.com/gha-indie-worker/gha-indie-worker-api-server.rs.git" ;;
    apps/gha-indie-worker-web-server.rs)
      url="https://github.com/gha-indie-worker/gha-indie-worker-web-server.rs.git" ;;
    *) echo "FAIL: unsupported submodule $path" >&2; exit 1 ;;
  esac
  expected="$(git rev-parse "HEAD:$path")"
  line="$(git ls-tree HEAD -- "$path")"
  expected_line="160000 commit $expected"$'\t'"$path"
  if [[ "$line" != "$expected_line" ]] ||
     [[ ! "$expected" =~ ^[0-9a-f]{40}$ ]]; then
    echo "FAIL: missing or malformed tracked Gitlink $path" >&2
    exit 1
  fi
  if [[ "$(git config -f .gitmodules --get "submodule.${path}.path")" != "$path" ]] ||
     [[ "$(git config -f .gitmodules --get "submodule.${path}.url")" != "$url" ]]; then
    echo "FAIL: .gitmodules path or URL differs from public allowlist for $path" >&2
    exit 1
  fi
done

echo "EXACT_HEAD=$(git rev-parse HEAD)"
echo "EXACT_TREE=$(git rev-parse 'HEAD^{tree}')"
# Gitlink commits are immutable; do not use a moving branch or Git tag.
git -c protocol.file.allow=never submodule update --init -- \
  apps/gha-indie-worker-api-server.rs apps/gha-indie-worker-web-server.rs

for path in "${services[@]}"; do
  expected="$(git rev-parse "HEAD:$path")"
  actual="$(git -C "$path" rev-parse HEAD)"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: materialized $path at $actual, expected $expected" >&2
    exit 1
  fi
  echo "PASS: materialized $path at $actual"
done
if [[ -n "$(git status --porcelain --ignore-submodules=untracked)" ]]; then
  echo "FAIL: superproject dirty after source materialization" >&2
  git status --short
  exit 1
fi
echo "PASS: two public Gitlinks materialized with pinned commit identities"
