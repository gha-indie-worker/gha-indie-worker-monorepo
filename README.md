# gha-indie-worker-monorepo

Exact source aggregation for the `gha-indie-worker` runtime family.

## Gitlink policy

- Runtime repositories are represented by tracked gitlinks at reviewed commit SHAs; `.gitmodules` declarations without a gitlink are not considered materialized source.
- `gha-indie-worker-infra` intentionally is **not** a monorepo submodule. Infra owns the canonical `.ores-compose.yaml` and itself tracks this monorepo, so adding the infra gitlink here would create a recursive submodule cycle.
- The first runnable slice materializes the API and web server gitlinks. Additional declared repositories may be promoted to tracked gitlinks independently after their exact revisions are reviewed.
- Consumers must use the recorded gitlinks. Never replace them with implicit `main`, tags, or another moving ref during execution.

## Laptop CI source adapter

The laptop IndieBuild continuity lane additionally uses `scripts/bootstrap-ci-worker.sh` to reconstruct the split `gha-indie-worker.rs` worker inside its immutable `ORESoftware/k8s-cluster` source-provenance workspace, because that worker intentionally retains `../../libs/*` path dependencies from the original tree. This is an operator-owned adapter, not a replacement for the monorepo's gitlink policy.

`scripts/run-ci-worker.sh` is the trusted runtime launcher for that lane. It validates App/webhook/auth inputs and requires the durable worker state directory to be an absolute operator-owned path outside this materialized source checkout before it execs the pinned worker binary.

The operator-owned smoke webhook policy is `config/ci-worker-webhook-rules.json`; repository-authored `.indiebuild.toml` may confirm policy but does not choose commands, credentials, push/deploy capability, or GitHub App identity.
