# acm-interop-p2p-cluster-install

Provisions an **ACM managed spoke** on the hub via Hive `ClusterDeployment`.

Assumes an ACM hub is already reachable (`KUBECONFIG` from CI Operator).

## Order of operations

1. Derive spoke name from `ACM_SPOKE_CLUSTER_NAME_PREFIX` + hub name hash; write `${SHARED_DIR}/managed-cluster-name`.
2. Create namespace, `ManagedClusterSet`, and `ManagedClusterSetBinding`.
3. Create hub secrets (AWS creds from `${CLUSTER_PROFILE_DIR}`, pull-secret, SSH keys) with idempotent `oc apply`.
4. Build install-config and install-config secret; resolve `ClusterImageSet` for `ACM_SPOKE_CLUSTER_INITIAL_VERSION`.
5. Create `ClusterDeployment`, `ManagedCluster`, and `KlusterletAddonConfig`.
6. Wait for `ClusterDeployment` condition **Provisioned=True** (`ACM_SPOKE_INSTALL_TIMEOUT_MINUTES`).
7. Write `${SHARED_DIR}/managed-cluster-kubeconfig` and `${SHARED_DIR}/managed.cluster.metadata.json`.

## Region

AWS region is **not** a step env var. The job must lease `MANAGED_CLUSTER_LEASED_RESOURCE`; the script exports it as `ACM_SPOKE_CLUSTER_REGION`.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ACM_SPOKE_ARCH_TYPE` | `amd64` | Control plane and worker architecture |
| `BASE_DOMAIN` | `cspilp.interop.ccitredhat.com` | Cluster base domain |
| `ACM_SPOKE_WORKER_REPLICAS` | `3` | Worker replicas |
| `ACM_SPOKE_CP_REPLICAS` | `3` | Control plane replicas |
| `ACM_SPOKE_CLUSTER_NAME_PREFIX` | `acm-spoke` | Spoke name prefix |
| `ACM_SPOKE_WORKER_TYPE` | `c5n.metal` | Worker instance type |
| `ACM_SPOKE_CP_TYPE` | `m6a.2xlarge` | Control plane instance type |
| `ACM_SPOKE_NETWORK_TYPE` | `OVNKubernetes` | Cluster network type |
| `ACM_SPOKE_INSTALL_TIMEOUT_MINUTES` | `150` | Provisioned wait timeout |
| `ACM_SPOKE_CLUSTER_INITIAL_VERSION` | `""` | Target OCP X.Y (job must set) |

## Failure diagnostics

On non-zero exit, writes `${ARTIFACT_DIR}/spoke-<cluster-name>-install-failure.txt` with ClusterDeployment state, events, and Hive controller log excerpts.
