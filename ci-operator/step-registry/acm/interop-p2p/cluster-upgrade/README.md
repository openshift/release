# acm-interop-p2p-cluster-upgrade

Upgrades the **hub cluster** to the latest Release Candidate (RC) image resolved from
`OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE`. Only the hub is upgraded here; spoke upgrade is handled
by a separate step. Cluster health checks run in the subsequent step.

## What it does

1. Resolves the target version string and image digest from `OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE`.
2. Patches `clusterversion/version` `spec.channel` to `ACM_CLUSTER_UPGRADE_TARGET_CHANNEL` (skipped if empty).
3. Patches `admin-acks-upgrades` when the Upgradeable condition references a required ack key (skipped if none).
4. Runs `oc adm upgrade --to-image=<repo>@<digest>` with explicit-upgrade flags.
5. Waits for `clusterversion/version` `status.history[0].version` to match the target version.
6. Waits for `status.history[0].state=Completed`.

## Requirements

- `KUBECONFIG` set by CI Operator to the hub cluster (automatic).
- `OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE` injected from the `release:target` dependency.
- Network access to pull release payloads via `oc adm release info`.
- `patch` on `clusterversions` and `adm upgrade` RBAC on the hub cluster.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ACM_CLUSTER_UPGRADE_TARGET_CHANNEL` | `""` | OCP update channel for the **hub** cluster (e.g. `candidate-4.21`). Empty = skip channel patch. |
| `ACM_UPGRADE_TIMEOUT` | `2h` | Timeout for each `oc wait` call. Accepts any `oc wait` duration (`30m`, `2h`, `7200s`). |

## Failure diagnostics

On non-zero exit, writes `${ARTIFACT_DIR}/hub-upgrade-failure.txt` with ClusterVersion state and recent cluster events.
