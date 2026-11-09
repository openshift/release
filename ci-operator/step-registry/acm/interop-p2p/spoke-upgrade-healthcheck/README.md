# acm-interop-p2p-spoke-upgrade-healthcheck

Post-upgrade health check for the **ACM managed spoke** after `acm-interop-p2p-spoke-upgrade`.

## Files

| File | Purpose |
|------|---------|
| `acm-interop-p2p-spoke-upgrade-healthcheck-ref.yaml` | Step registry ref (verification-tests image, same as cucushift) |
| `acm-interop-p2p-spoke-upgrade-healthcheck-commands.sh` | Sets spoke `KUBECONFIG`, then runs cucushift upgrade healthcheck logic |

The commands script embeds the body of
[`cucushift-upgrade-healthcheck-commands.sh`](../../../cucushift/upgrade/healthcheck/cucushift-upgrade-healthcheck-commands.sh)
without modifying the upstream file. When updating health check behavior, change cucushift first, then
refresh the embedded section in `acm-interop-p2p-spoke-upgrade-healthcheck-commands.sh`.

## Checks

1. MachineConfigPools — not Updating/Degraded, stable for 5 minutes (wait budget `max(ACM_SPOKE_MCP_READY_TIMEOUT_MINUTES, nodes × ACM_SPOKE_MCP_MINUTES_PER_NODE)`; defaults 210m / 35m per node)
2. Cluster operators — Available, not Progressing, not Degraded (`ACM_SPOKE_CO_READY_TIMEOUT_MINUTES`, default 45m)
3. Nodes — all Ready
4. Pods — status dump for reference

## Step timeout

| Setting | Default | Purpose |
|---------|---------|---------|
| `timeout` (ref.yaml) | 5h | MCP + CO budgets + margin (fits within 20h job) |
| `ACM_SPOKE_MCP_READY_TIMEOUT_MINUTES` | 210 | MCP wait floor |
| `ACM_SPOKE_MCP_MINUTES_PER_NODE` | 35 | MCP wait per node |
| `ACM_SPOKE_CO_READY_TIMEOUT_MINUTES` | 45 | CO stability poll budget |
| `grace_period` | 10m | EXIT trap diagnostics after step failure |

## Requirements

| File | Source step |
|------|-------------|
| `${SHARED_DIR}/managed-cluster-kubeconfig` | `acm-interop-p2p-cluster-install` |

## Artifacts on failure

| File | Content |
|------|---------|
| `spoke-<name>-upgrade-healthcheck-failure.txt` | ClusterVersion, MCP describe, not-Ready node describe, unhealthy CO describe, MCO pods |

## Typical workflow placement

```yaml
test:
- ref: acm-interop-p2p-spoke-upgrade
- ref: acm-interop-p2p-spoke-upgrade-healthcheck
- ref: interop-tests-openshift-virtualization-upgrade-tests
```
