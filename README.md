# gha-indie-worker-monorepo

Pinned source graph for gha-indie-worker local development and operator-owned tooling.

Application repositories are sourced through the pinned monorepo graph. The laptop IndieBuild continuity lane additionally uses `scripts/bootstrap-ci-worker.sh` to reconstruct the split `gha-indie-worker.rs` worker inside its immutable `ORESoftware/k8s-cluster` source-provenance workspace, because that worker intentionally retains `../../libs/*` path dependencies from the original tree.

`scripts/run-ci-worker.sh` is the trusted runtime launcher for that lane. It validates App/webhook/auth inputs and requires the durable worker state directory to be an absolute operator-owned path outside this materialized source checkout before it execs the pinned worker binary.

The operator-owned smoke webhook policy is `config/ci-worker-webhook-rules.json`; repository-authored `.indiebuild.toml` may confirm policy but does not choose commands, credentials, push/deploy capability, or GitHub App identity.
