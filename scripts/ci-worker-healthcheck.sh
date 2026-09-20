#!/usr/bin/env bash
set -euo pipefail

# ores-compose currently admits one service environment for build/start/probe.
# The long-running worker needs these values; curl does not. Remove sensitive
# bindings in-shell before any external process is created, then replace this
# shell with the readiness probe.
unset BUILD_SERVER_GITHUB_APP_PRIVATE_KEY_PATH
unset BUILD_SERVER_GITHUB_WEBHOOK_SECRET
unset BUILD_SERVER_AUTH_SECRET
unset BUILD_SERVER_GIT_TOKEN
unset GH_PAT
unset GITHUB_TOKEN

exec curl --fail --silent --show-error http://127.0.0.1:8100/readyz
