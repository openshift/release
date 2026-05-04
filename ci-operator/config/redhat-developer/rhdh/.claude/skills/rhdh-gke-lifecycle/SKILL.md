---
name: rhdh-gke-lifecycle
description: >-
  Check GKE Kubernetes version support status. GKE uses a long-running static
  cluster whose version is not managed in CI config
allowed-tools: Bash(bash *check-k8s-lifecycle.sh*), WebFetch
---
# Check GKE Kubernetes Version Lifecycle

GKE uses a pre-existing long-running cluster. The K8s version is NOT in CI config — updates require manual intervention on the cluster itself.

## Prerequisites

- `curl`, `jq`, internet connectivity

## Steps

1. Run the lifecycle check script:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-k8s-lifecycle.sh" \
  --api-url https://endoflife.date/api/google-kubernetes-engine.json
```

2. Cross-verify by fetching the vendor docs and comparing supported versions:

```
WebFetch https://cloud.google.com/kubernetes-engine/docs/release-notes
```

Report any discrepancies between endoflife.date and the vendor page.
