# acm-interop-p2p-cluster-uninstall

Deprovisions a **Hive-managed ACM spoke** from the hub after test/post phase.

## Order of operations

1. Delete `ManagedCluster`; wait up to `ACM_CLUSTER_MC_DETACH_TIMEOUT_MINUTES` for ACM to clear finalizers. If still stuck (spoke unreachable), finalizers are auto-stripped so deprovisioning can always proceed.
2. Delete `KlusterletAddonConfig`
3. Patch and delete `ClusterDeployment` (`preserveOnDelete=false`) to trigger Hive deprovision
4. Wait for `ClusterDeprovision` object to be auto-created by Hive
5. Wait for `ClusterDeprovision.status.completed=true`
6. Delete `ManagedClusterSetBinding` and `ManagedClusterSet`

Spoke cluster health does not block hub-side deprovision; hub namespace must retain metadata secrets and AWS credentials.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ACM_CLUSTER_MC_DETACH_TIMEOUT_MINUTES` | `10` | Minutes to wait for ACM to clear `ManagedCluster` finalizers before auto-stripping them |
| `ACM_CLUSTER_DEPROVISION_TIMEOUT_MINUTES` | `60` | Minutes to wait per cluster for `ClusterDeprovision` to complete |
| `ACM_CLUSTER_DEPROVISION_POLL_SECONDS` | `10` | Poll interval while waiting for `ClusterDeprovision` to appear |
| `ACM_CLUSTER_UNINSTALL_FORCE_DELETE_MC` | `false` | Strip `ManagedCluster` finalizers immediately on delete, skipping the detach wait |

## Failure diagnostics

On non-zero exit, writes:
- `${ARTIFACT_DIR}/managed-clusters-on-failure.txt` — hub `ManagedCluster` listing
- `${ARTIFACT_DIR}/deprovisions-on-failure.txt` — all `ClusterDeprovision` objects across namespaces
- `${ARTIFACT_DIR}/spoke-<cluster-name>-deprovision-stuck.txt` — full describe of a `ClusterDeprovision` that timed out (written only when deprovision wait times out)
