#!/usr/bin/env bash
set -euo pipefail

# The tunnel process needs TUNNEL_TOKEN; its local readiness probe does not.
# Remove the token before curl is created so healthcheck helpers never receive
# the Cloudflare credential.
unset TUNNEL_TOKEN
unset INDIEBUILD_CLOUDFLARE_TUNNEL_TOKEN

exec curl --fail --silent --show-error http://127.0.0.1:18096/ready
