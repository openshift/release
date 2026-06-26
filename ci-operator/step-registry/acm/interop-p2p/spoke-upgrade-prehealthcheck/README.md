# ACM Interop P2P Spoke Upgrade Pre-healthcheck

## Purpose

Run cucushift-style pre-upgrade health checks against every ACM managed spoke cluster
on the hub before `acm-interop-p2p-spoke-upgrade`.

## Process

1. Connect to the ACM hub using `${SHARED_DIR}/kubeconfig`.
2. Resolve the spoke list from `ACM_INTEROP_P2P__PREHEALTHCHECK__SPOKE_CLUSTERS` when set,
   or discover all `ManagedCluster` resources except `local-cluster`.
3. For each spoke, resolve an admin kubeconfig from `${SHARED_DIR}/managed-cluster-kubeconfig`
   (when the spoke name matches `${SHARED_DIR}/managed-cluster-name`) or from the Hive
   `ClusterDeployment` admin kubeconfig secret.
4. Run MCP, ClusterOperator, node, and pod checks on each spoke (same logic as
   `cucushift-upgrade-prehealthcheck`).
5. On per-spoke failure, write `spoke-<name>-upgrade-prehealthcheck-failure.txt` to
   `${ARTIFACT_DIR}`.

## Environment Variables

| Name | Default | Description |
| --- | --- | --- |
| `ACM_INTEROP_P2P__PREHEALTHCHECK__SPOKE_CLUSTERS` | empty | Optional comma-separated spoke names. When empty, all managed spokes are checked. |

## Requirements

- Hub kubeconfig at `${SHARED_DIR}/kubeconfig`
- At least one managed spoke registered with ACM
- Hive-provisioned spokes must expose `ClusterDeployment.spec.clusterMetadata.adminKubeconfigSecretRef`
