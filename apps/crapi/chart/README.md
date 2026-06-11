# Vendored crAPI Helm chart

This directory holds the upstream OWASP crAPI Helm chart from
[github.com/OWASP/crAPI/tree/main/deploy/helm](https://github.com/OWASP/crAPI/tree/main/deploy/helm).

It is intentionally vendored (committed to this repo) so:

- The lab is reproducible — a given commit always deploys the same chart
- `task up` works without internet access
- Upstream changes can't break the lab silently between runs

## First-time setup

If this directory is empty (fresh clone), populate it from upstream:

```bash
task crapi:chart:update
```

That fetches `main` by default. To pin a different ref:

```bash
CRAPI_REF=develop  task crapi:chart:update    # bleeding edge
CRAPI_REF=v1.4.0   task crapi:chart:update    # specific tag
```

The pinned ref and commit SHA land in `../CHART_VERSION` for the record.

## Refreshing later

```bash
task crapi:chart:update      # download new version
git status apps/crapi/       # see what changed
git diff apps/crapi/CHART_VERSION
git diff --stat apps/crapi/chart/
# Inspect, test, commit
```

## Lab overrides

The chart's defaults are overridden by `../values.yaml` — that's where the
NodePort/LoadBalancer/TLS adjustments live. Don't edit the vendored chart
files directly; if you need a change the chart doesn't expose, raise it
upstream or use a Helm post-renderer.
