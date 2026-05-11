---
name: rhdh-gke-tests
description: >-
  List GKE test entries in RHDH ci-operator config files and upgrade the GKE
  cluster Kubernetes version using gcloud CLI
allowed-tools: Bash(bash *list-k8s-test-configs.sh*), WebFetch
---
# RHDH GKE Test Management

List GKE test entries and manage the long-running GKE cluster K8s version.

Unlike AKS/EKS which set `MAPT_KUBERNETES_VERSION` in CI config files, GKE uses
a pre-existing static cluster. Version upgrades are performed via the GCP Console.

## When to Use

- List which GKE test entries exist per RHDH release branch
- Check the current cluster K8s version and available upgrades

## Prerequisites

- `yq` (v4+) for listing tests

## Listing Tests

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/list-k8s-test-configs.sh" \
  --pattern "^e2e-gke-"
```

Filter by branch: add `--branch main`.

## Checking and Upgrading the Cluster Version

The GKE cluster details (name, region, project) are stored in the `rhdh` secret
under `test-credentials`. To check the current version and perform upgrades,
use the GCP Console:

1. Open the [GKE clusters page](https://console.cloud.google.com/kubernetes/list/overview)
2. Select the correct project
3. Click on the cluster to view version details and available upgrades

**NOTE**: `make update` is NOT required -- the version lives on the cluster, not in CI config.

## Related Skills

- **`rhdh-gke-lifecycle`**: Check which K8s versions are supported before upgrading
