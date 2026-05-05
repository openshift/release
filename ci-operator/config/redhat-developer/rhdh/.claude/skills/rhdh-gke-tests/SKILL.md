---
name: rhdh-gke-tests
description: >-
  List GKE test entries in RHDH ci-operator config files and upgrade the GKE
  cluster Kubernetes version using gcloud CLI
allowed-tools: Bash(bash *inspect-gke-cluster.sh*), Bash(bash *list-k8s-test-configs.sh*), Bash(gcloud *)
---
# RHDH GKE Test Management

List GKE test entries and check the long-running GKE cluster K8s version.

Unlike AKS/EKS which set `MAPT_KUBERNETES_VERSION` in CI config files, GKE uses
a pre-existing static cluster. Version upgrades are performed via the GCP Console.

## When to Use

- List which GKE test entries exist per RHDH release branch
- Check the current cluster K8s version and available upgrades
- Get a direct link to the GCP Console to perform an upgrade

## Prerequisites

- `gcloud` CLI authenticated to the GCP project containing the cluster
- `curl`, `jq` for version lookups
- `yq` (v4+) for listing tests

## Listing Tests

```bash
bash "${CLAUDE_SKILL_DIR}/../rhdh-aks-tests/scripts/list-k8s-test-configs.sh" \
  --pattern "^e2e-gke-"
```

Filter by branch: add `--branch main`.

## Inspecting the Cluster

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/inspect-gke-cluster.sh"
```

The script auto-discovers the cluster name, project, and zone from `gcloud`.
It shows:
1. Current master and node pool versions
2. Available versions from `gcloud container get-server-config`
3. Lifecycle status from endoflife.date
4. Available upgrades (patch and minor) with a direct GCP Console link

### Overriding auto-detection

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/inspect-gke-cluster.sh" \
  --project my-project --cluster my-cluster --zone us-east1-b
```

## Upgrading the Cluster

Upgrades are performed manually via the GCP Console. The inspect script prints
the direct URL when upgrades are available:

```
https://console.cloud.google.com/kubernetes/clusters/details/<zone>/<cluster>/details?project=<project>
```

**NOTE**: `make update` is NOT required — the version lives on the cluster, not in CI config.

## Scripts

| Script | Purpose |
|---|---|
| `inspect-gke-cluster.sh` | Current state, available versions, lifecycle, upgrade proposal with Console link |

## Related Skills

- **`rhdh-gke-lifecycle`**: Check which K8s versions are supported before upgrading
