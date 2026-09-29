# CLUSTER_INSTABILITY Classification (Step 4)

This is the classification rule for `CLUSTER_INSTABILITY`, shared by every QE agent skill. The skill's Step 4 gives you the operator-specific commands to enable debug logging and read the operator logs. Apply this module to what they show.

`CLUSTER_INSTABILITY` is easy to over-call, because a tight operator reconciliation loop looks the same from outside: API server pressure, slow reconciles, timeouts. Rule the loop out first.

## 1. Rule out a reconciliation loop

A loop shows as: the same resource reconciled more than once every 2–3 seconds; sub-second `requeue` entries with no intervening success or "Reconciling finished" message; queue depth growing over time; or rate-limiting `Reconciler error` followed by rapid requeue.

A healthy operator shows reconciles of the same object 10 or more seconds apart, no sub-second `requeue` entries, and low, stable log volume.

If a loop is found, reclassify as `PRODUCT_BUG` and write the bug report in Step 5b.

## 2. The four conditions

Classify as `CLUSTER_INSTABILITY` only when **all four** hold:

1. **Cluster was moving.** The MachineConfigPools were updating (`UPDATING=True` or `UPDATED=False`) at the original test time, or the operator pod shows `RESTARTS > 0` (for example probe failures or leader election loss) correlated with the MCP rollout.
2. **Reruns pass cleanly.** All reruns pass, with a shorter duration than the original run.
3. **No fixable test defect.** If a timeout, version pin, selector or assertion would fail under foreseeable cluster load, including normal scheduling pressure during node updates, that is a `TEST_ISSUE` to fix, not infrastructure instability.
4. **No tight reconciliation loop** (section 1).

When all four hold, `CLUSTER_INSTABILITY` takes precedence over `FLAKY`. Proceed to Step 5d.

If the evidence does not settle it, gather more cluster evidence before deciding, and explain your reasoning explicitly in the output. Cite the MCP status, restart counts and durations you relied on: the incident note and the analysis summary both need them.
