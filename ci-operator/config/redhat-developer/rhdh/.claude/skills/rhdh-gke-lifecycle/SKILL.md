---
name: rhdh-gke-lifecycle
description: >-
  Check GKE Kubernetes version support status using the endoflife.date API
  (auto-scraped from Google's GKE release schedule). Use whenever someone asks
  about GKE K8s version support, EOL dates, or whether the current GKE cluster
  version is still supported. GKE uses a long-running static cluster whose
  version is not managed in CI config.
allowed-tools: Bash(bash *check-gke-lifecycle.sh*), WebFetch
---
# Check GKE Kubernetes Version Lifecycle

GKE uses a pre-existing long-running cluster. The K8s version is NOT in CI config — updates are performed via the GCP Console.

## When to Use

- Check if the current GKE cluster K8s version is still supported
- Find which K8s versions GKE supports and their EOL dates
- Before upgrading the GKE cluster via the GCP Console

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

```text
WebFetch https://cloud.google.com/kubernetes-engine/docs/release-schedule
```

## Interpreting Results

The script outputs supported GKE K8s versions with their support status and dates:

- **Standard**: actively supported, receives regular patches and security updates
- **Maintenance**: past standard support end date but still receives critical security patches for a limited time
- Versions past both standard and maintenance support are not shown

## Action

**Always recommend upgrading to the newest Standard version.** Since GKE version is not in CI config, check the actual cluster version via the GCP Console. If the cluster is not on the newest Standard version, recommend upgrading via the [GKE clusters page](https://console.cloud.google.com/kubernetes/list/overview).

## Related Skills

- **`rhdh-gke-tests`**: List GKE test entries
