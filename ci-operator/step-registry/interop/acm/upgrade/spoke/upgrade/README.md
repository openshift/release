# interop-acm-upgrade-spoke-upgrade

Upgrades the **ACM managed spoke** OCP version after the hub upgrade step.

## Design (spoke bootstrap + hub ManifestWork)

| Step | Where | What |
|------|-------|------|
| Channel patch | Spoke (admin kubeconfig) | `ClusterVersion.spec.channel` when `TARGET_CHANNEL` is set |
| Admin-ack | Spoke | `admin-acks-upgrades` from Upgradeable condition |
| RBAC bootstrap | Spoke | `klusterlet-work-clusterversion` for `klusterlet-work-sa` |
| Upgrade trigger | Hub | `ManifestWork` with `desiredUpdate.image` (digest-pinned) |
| Wait | Spoke | `oc wait` on `ClusterVersion` Completed |

Post-upgrade MCP, cluster operator, and node health checks run in
`interop-acm-upgrade-spoke-healthcheck`.

## Requirements

| File | Source step |
|------|-------------|
| `${SHARED_DIR}/kubeconfig` | `acm-fetch-managed-clusters` |
| `${SHARED_DIR}/managed-cluster-kubeconfig` | `interop-acm-cclm-spoke-cluster-install` |
| `${SHARED_DIR}/managed-cluster-name` | `interop-acm-cclm-spoke-cluster-install` (ManifestWork namespace = cluster name) |
| `OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE` | `release:target` dependency |

## Typical workflow placement

```yaml
test:
- ref: interop-acm-cclm-spoke-cluster-install
- ref: acm-fetch-managed-clusters
- ref: acm-interop-p2p-cluster-upgrade
- ref: cucushift-upgrade-healthcheck          # hub
- ref: interop-acm-upgrade-spoke-upgrade
- ref: interop-acm-upgrade-spoke-healthcheck
- ref: interop-tests-openshift-virtualization-upgrade-tests
```

## Artifacts

| File | Content |
|------|---------|
| `spoke-<name>-clusterversion-rbac.yaml` | ClusterRole/Binding applied on spoke |
| `spoke-<name>-ocp-upgrade-manifestwork.yaml` | ManifestWork spec (image reference only) |
