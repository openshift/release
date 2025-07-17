# Cluster Upgrade Step

## What this step does ?

Assumes an ACM hub is already reachable, Spoke/Managed cluster is installed

1. Reads kubecnfig for the  hub and spoke clusters

2. Resolves the given release tag(e.g., 4.20.0-rc.2-x86_64) to its immutable @sha256:digest using oc adm release info on each cluster

3. Sets the upgrade channel to candidate-4.20

4. Triggers the upgrade with oc adm upgrade --to-image=<repo>@<digest> on hub, then spoke.

5. Waits until ClusterVersion reports state=Completed and status.desired.image matches the target digest

## Requirements

1. oc and jq avaialable

2. Hub kubeconfig available in location <SHARED_DIR/kubeconfig>, and spoke kubeconfig available in location "<SHARED_DIR/managed-cluster-kubeconfig>"

3. Network access to pull release payloads

4. RBAC sufficient to read and patch clusterversion on each cluster

