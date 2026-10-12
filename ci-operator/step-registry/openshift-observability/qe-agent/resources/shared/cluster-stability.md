# Cluster Stability Check (Step 0a)

This is the body of Step 0a, shared by every QE agent skill. Run it before Step 0b. When you finish, keep the final `oc get machineconfigpools` output: Step 5d cites it as the MCP snapshot.

Before running any prerequisites setup or test reruns, confirm the cluster is stable. The original CI test step may have applied resources that triggered MachineConfig updates — running tests while nodes are updating causes spurious failures.

```bash
oc get machineconfigpools.machineconfiguration.openshift.io
```

Each MachineConfigPool must have `UPDATED=True`, `UPDATING=False`, and `DEGRADED=False` before proceeding.

**If any pool is not ready**, wait and recheck every 60 seconds:

```bash
# Wait until all MCPs are updated, not updating, and not degraded.
# Split into two 10-minute phases to stay within the Bash tool's timeout limit.
# Phase 1: wait up to 10 minutes
deadline=$((SECONDS + 600))
mcp_ready() {
  local status
  status=$(oc get machineconfigpools.machineconfiguration.openshift.io \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Updated")].status}{" "}{.status.conditions[?(@.type=="Updating")].status}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}') || return 1
  [[ -n "${status}" ]] || return 1
  ! grep -qvE '^True False False$' <<<"${status}"
}
until mcp_ready; do
  echo "MCPs not ready yet (or the query failed), waiting 60s..."
  if (( SECONDS >= deadline )); then
    echo "Phase 1 timeout — MCPs still not ready after 10 minutes. Continuing in phase 2."
    oc get machineconfigpools.machineconfiguration.openshift.io
    break
  fi
  sleep 60
  oc get machineconfigpools.machineconfiguration.openshift.io
done
```

If the first phase did not converge (the loop exited via the `break`), run a second Bash invocation to continue waiting:

```bash
# Phase 2: wait up to 10 more minutes (total 20 minutes across both phases)
deadline=$((SECONDS + 600))
mcp_ready() {
  local status
  status=$(oc get machineconfigpools.machineconfiguration.openshift.io \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Updated")].status}{" "}{.status.conditions[?(@.type=="Updating")].status}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}') || return 1
  [[ -n "${status}" ]] || return 1
  ! grep -qvE '^True False False$' <<<"${status}"
}
until mcp_ready; do
  echo "MCPs not ready yet (or the query failed), waiting 60s..."
  if (( SECONDS >= deadline )); then
    echo "ERROR: MCPs still not ready after 20 minutes — cluster is unhealthy."
    oc get machineconfigpools.machineconfiguration.openshift.io
    exit 1
  fi
  sleep 60
  oc get machineconfigpools.machineconfiguration.openshift.io
done
echo "All MCPs ready — proceeding."
```

If Phase 2 also times out, don't hard-stop — skip to Step 6. If the `oc get machineconfigpools` output above lists pools (not-ready), classify as `CLUSTER_INSTABILITY` (Step 5d's contract); if the query itself failed (no pools printed), record the MCP status as unavailable and set Outcome to a rerun recommendation instead.
