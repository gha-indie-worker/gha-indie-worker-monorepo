# gha-indie-worker-monorepo

Exact source aggregation for the `gha-indie-worker` runtime family.

## Gitlink policy

- Runtime repositories are represented by tracked gitlinks at reviewed commit SHAs; `.gitmodules` declarations without a gitlink are not considered materialized source.
- `gha-indie-worker-infra` intentionally is **not** a monorepo submodule. Infra owns the canonical `.ores-compose.yaml` and itself tracks this monorepo, so adding the infra gitlink here would create a recursive submodule cycle.
- The first runnable slice materializes the API and web server gitlinks. Additional declared repositories may be promoted to tracked gitlinks independently after their exact revisions are reviewed.
- Consumers must use the recorded gitlinks. Never replace them with implicit `main`, tags, or another moving ref during execution.
