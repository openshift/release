---
name: rhdh-gke-lifecycle
description: >-
  Check GKE Kubernetes version support status. GKE uses a long-running static
  cluster whose version is not managed in CI config
allowed-tools: Bash(bash *check-gke-lifecycle.sh*), WebFetch
---
# Check GKE Kubernetes Version Lifecycle

GKE uses a pre-existing long-running cluster. The K8s version is NOT in CI config — updates are performed via the GCP Console.

## Prerequisites

- `curl`, `jq`, internet connectivity

## Steps

1. Run the lifecycle check script:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-gke-lifecycle.sh"
```

The script queries:
- **Primary**: `https://endoflife.date/api/google-kubernetes-engine.json` — auto-scraped from Google's GKE release schedule page, shows standard/maintenance support status and EOL dates

2. If the API call fails, fall back to the vendor docs:

```
WebFetch https://cloud.google.com/kubernetes-engine/docs/release-schedule
```

## Related Skills

- **`rhdh-gke-tests`**: List GKE test entries and manage the cluster version
