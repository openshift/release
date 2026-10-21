# Build Farm Scheduling Pressure

**Alerts:** `BuildFarmHighPendingPods`, `BuildFarmNodePressure` — **Slack:** `#ops-testplatform`. **Rules:** [`build-farm-scheduling-pressure_prometheusrule.yaml`](../../clusters/build-clusters/build-shared/openshift-monitoring/build-farm-scheduling-pressure_prometheusrule.yaml) (per build cluster). **Severity:** `warning`.

## What the alerts mean

- **BuildFarmHighPendingPods**: More than 50 pods in namespace `ci` in phase Pending for 10 minutes on this build cluster. Scheduling is not keeping up.
- **BuildFarmNodePressure**: At least one node has MemoryPressure, DiskPressure, or PIDPressure for 10 minutes. Can lead to evictions and slow scheduling.

## Why we alert

Scheduling pressure causes CI jobs to hold plank slots longer (pods wait to be scheduled; each job runs 5–30 pods). That contributes to plank saturation before "pods failed to schedule" is obvious. Plank metrics don’t show how healthy already-created pods are w.r.t. scheduling—you need build-farm data. See [Configuration](#configuration) at the end for where the rule and routing live.

---

## How to fix

### Step 1: Identify affected cluster(s) and get a snapshot

From the Slack alert, note which build cluster is firing (alert is evaluated per cluster). Then get node pressure and pending counts for all build clusters:

```bash
echo "CLUSTER      NODE_PRESSURE   PENDING_PODS" && for c in build01 build02 build03 build04 build05 build06 build07 build08 build09 build10 build11; do p=$(oc --context $c get nodes -o json 2>/dev/null | jq -r '[.items[] | select(.status.conditions[] | select((.type=="MemoryPressure" or .type=="DiskPressure" or .type=="PIDPressure") and .status=="True"))] | length'); n=$(oc --context $c get pods -n ci --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l); printf "%-10s  %14s  %11s\n" "$c" "$p" "$n"; done
```

Set the affected context (e.g. replace `build01` with the cluster from the alert):

```bash
ctx=build01   # or build02, build06, etc.
```

---

### Step 2: Diagnose pending pods (BuildFarmHighPendingPods)

**List pending pods and age:**

```bash
oc --context $ctx get pods -n ci --field-selector=status.phase=Pending -o custom-columns='NAME:.metadata.name,AGE:.metadata.creationTimestamp'
```

**See why pods are pending (reason and message):**

```bash
oc --context $ctx get pods -n ci --field-selector=status.phase=Pending -o json | jq -r '.items[] | .metadata.name as $n | .status.conditions[]? | select(.reason) | "\($n): \(.reason) - \(.message // "")"'
```

**Recent FailedScheduling events (scheduling impossible):**

```bash
oc --context $ctx get events -n ci --field-selector reason=FailedScheduling -o custom-columns='LAST:.lastTimestamp,COUNT:.count,MESSAGE:.message' | tail -20
```

**Interpretation:**

- **ContainersNotReady / ContainersNotInitialized**: Pod is scheduled; init or main containers still starting. Normal if age is low; no fix needed.
- **Unschedulable** (or FailedScheduling events): Pod cannot be placed. Message usually says: no node match (taints, affinity), or insufficient resources. Fix: add capacity (MachineSets/autoscaler) or fix placement (taints/labels) if it’s a constraint mismatch.

---

### Step 3: Fix high pending pods

- **If most pending are ContainersNotReady/ContainersNotInitialized and age &lt; few minutes:** No action; they’re starting. Re-check with the table one-liner in 5–10 minutes.
- **If many Unschedulable / FailedScheduling (e.g. “0/N nodes available”):**
  - **Resource capacity:** Cluster is full. MachineAutoscaler should scale out; check MachineSets and autoscaler on the cluster (e.g. `oc --context $ctx get machinesets -n openshift-machine-api`, `oc --context $ctx get machineautoscalers -n openshift-machine-api`). If autoscaler is at max or scaling is slow, consider temporary scale-up or follow-up with cluster admins.
  - **Taints / affinity mismatch:** Message will mention “didn’t match Pod’s node affinity” or “untolerated taint”. Usually a job needs a specific pool (e.g. `ci-builds-worker`); ensure that pool has ready nodes. No generic fix—address the specific pool or relax the job’s constraints if misconfigured.
- **One or two old Unschedulable pods (e.g. stuck for days):** Often a misconfigured or obsolete job. Find the ProwJob (e.g. from pod labels), consider aborting the job or fixing its cluster/pool assignment.

---

### Step 4: Diagnose node pressure (BuildFarmNodePressure)

**Which nodes have pressure:**

```bash
oc --context $ctx get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select((.type=="MemoryPressure" or .type=="DiskPressure" or .type=="PIDPressure") and .status=="True")) | .metadata.name'
```

**Resource usage per node (CPU and memory):**

```bash
oc --context $ctx adm top nodes
```

**Optional – which condition is True (MemoryPressure vs DiskPressure vs PIDPressure):**

```bash
oc --context $ctx get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select((.type=="MemoryPressure" or .type=="DiskPressure" or .type=="PIDPressure") and .status=="True")) | "\(.metadata.name): \(.status.conditions[] | select(.type | test("Pressure")) | "\(.type)=\(.status)")"' 
```

---

### Step 5: Fix node pressure

- **MemoryPressure:** Cluster or node is short on memory. Check `oc adm top nodes`; consider cordoning/draining heavily used nodes if a single workload is the cause, or scaling the pool (MachineSets/autoscaler). Evictions may already be happening; check for Evicted pods: `oc --context $ctx get pods -n ci --field-selector=status.phase=Failed -o custom-columns='NAME:.metadata.name,AGE:.metadata.creationTimestamp,REASON:.status.reason' | grep -E 'Evicted|OOM'`.
- **DiskPressure:** Node disk (or image store) full. Usually requires cleaning images/containers on the node or replacing the node; see OpenShift docs for [reclaiming node disk space](https://docs.openshift.com/container-platform/latest/nodes/nodes/nodes-node-managing.html#nodes-node-reclaiming-disk_nodes-node-managing).
- **PIDPressure:** Too many PIDs on the node. Less common; may require restarting the node or identifying and limiting the workload that creates many processes.

After any fix, re-run the table one-liner and confirm NODE_PRESSURE and PENDING_PODS drop; alerts should clear once below threshold for 10m.

---

## Useful commands and queries (reference)

All commands use `oc` with the appropriate build-cluster context (`$ctx` or replace with e.g. `build01`). Namespace is `ci` unless noted.

| Purpose | Command |
|--------|---------|
| Table: node pressure + pending pods (all clusters) | `echo "CLUSTER      NODE_PRESSURE   PENDING_PODS" && for c in build01 build02 build03 build04 build05 build06 build07 build08 build09 build10 build11; do p=$(oc --context $c get nodes -o json 2>/dev/null \| jq -r '[.items[] \| select(.status.conditions[] \| select((.type=="MemoryPressure" or .type=="DiskPressure" or .type=="PIDPressure") and .status=="True"))] \| length'); n=$(oc --context $c get pods -n ci --field-selector=status.phase=Pending --no-headers 2>/dev/null \| wc -l); printf "%-10s  %14s  %11s\n" "$c" "$p" "$n"; done` |
| Pending pod count (one cluster) | `oc --context $ctx get pods -n ci --field-selector=status.phase=Pending --no-headers \| wc -l` |
| Pending pods with age | `oc --context $ctx get pods -n ci --field-selector=status.phase=Pending -o custom-columns='NAME:.metadata.name,AGE:.metadata.creationTimestamp'` |
| Pending pod reasons | `oc --context $ctx get pods -n ci --field-selector=status.phase=Pending -o json \| jq -r '.items[] \| .metadata.name as $n \| .status.conditions[]? \| select(.reason) \| "\($n): \(.reason) - \(.message // "")"'` |
| FailedScheduling events | `oc --context $ctx get events -n ci --field-selector reason=FailedScheduling -o custom-columns='LAST:.lastTimestamp,COUNT:.count,MESSAGE:.message'` |
| Nodes with pressure (names) | `oc --context $ctx get nodes -o json \| jq -r '.items[] \| select(.status.conditions[] \| select((.type=="MemoryPressure" or .type=="DiskPressure" or .type=="PIDPressure") and .status=="True")) \| .metadata.name'` |
| Node CPU/memory usage | `oc --context $ctx adm top nodes` |
| Failed/Evicted pods (sample) | `oc --context $ctx get pods -n ci --field-selector=status.phase=Failed -o custom-columns='NAME:.metadata.name,AGE:.metadata.creationTimestamp,REASON:.status.reason' \| tail -20` |
| MachineSets (capacity) | `oc --context $ctx get machinesets -n openshift-machine-api -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas'` |
| MachineAutoscalers (min/max) | `oc --context $ctx get machineautoscalers -n openshift-machine-api -o custom-columns='NAME:.metadata.name,MIN:.spec.minReplicas,MAX:.spec.maxReplicas'` |

Plank/job-level view (on app.ci): [plank dashboard](https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/e1778910572e3552a935c2035ce80369/plank-dashboard) — triggered vs pending job counts; workqueue_depth for plank/crier in Prometheus indicates controller backlog.

---

## Configuration

- **PrometheusRule**: `clusters/build-clusters/build-shared/openshift-monitoring/build-farm-scheduling-pressure_prometheusrule.yaml` (applied to build clusters via gitops).
- **Alert routing**: Build cluster Alertmanagers route these alert names to **#ops-testplatform**. In this repo, `alertmanager-main_secret_template.yaml` under `clusters/build-clusters/01_cluster/openshift-monitoring/` and `clusters/build-clusters/build02/openshift-monitoring/` include the route; other build clusters may use the same pattern from shared config.
