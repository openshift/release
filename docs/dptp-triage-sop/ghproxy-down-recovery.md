# ghproxy Down / Crash Recovery

## Alert binding

| Field | Value |
|-------|-------|
| **Alert** | `ghproxy-down` (component monitor) |
| **Cluster** | `app.ci` |
| **Check** | `max(up{job="ghproxy"}) > 0` — fires when ghproxy metrics target is unreachable |
| **Dashboard** | SHIP Status Dashboard (auto-clears when component monitor detects ghproxy is back up) |
| **Severity** | `critical` |

This SOP covers recovery when `ghproxy` is **down** on `app.ci`.

## What this alert means

The ghproxy pod is not running or not serving traffic. All Prow components
that proxy GitHub API calls through ghproxy will fail, causing widespread
CI disruption.

ghproxy is a single-replica Deployment with a `Recreate` strategy
([deployment YAML](../../clusters/app.ci/prow/03_deployment/ghproxy.yaml)).
It runs in namespace **`ci`** with labels **`app=prow`**, **`component=ghproxy`**
and mounts a **30 Gi gp2 RWO** PVC (`ghproxy`) at `/cache` with `--cache-sizeGB=19`.

Because ghproxy only has a memory *request* of 250 Mi with **no limit**
(Burstable QoS), it is a prime eviction target when its node is under
memory pressure.

### Known failure chain

1. Node memory pressure → kubelet evicts ghproxy (Burstable QoS).
2. Scheduler places the new pod on a **different** node.
3. The RWO PVC is still attached to the old node → `Multi-Attach error`.
4. Each rescheduling attempt creates another `Failed` pod that also holds
   a PVC claim reference, deepening the deadlock.
5. Even after the old attachment releases, zombie cache directories cause
   **SELinux relabeling** delays on startup (the pod stays
   `ContainerCreating` for minutes).

### Impact scope

The disk cache is purely a GitHub API optimisation. Wiping it causes a
short-lived increase in uncached requests but has **no lasting impact**
on correctness or data.

## When to react

React **immediately** — ghproxy being down is a CI-wide outage.

## Diagnose on-cluster (`app.ci`)

```bash
CTX=app.ci
```

### 1) Check pod status and events

```bash
oc --context "$CTX" get pods -n ci -l app=prow,component=ghproxy -o wide
oc --context "$CTX" describe pod -n ci -l app=prow,component=ghproxy
```

Look for:

| Symptom | Meaning |
|---------|---------|
| `CrashLoopBackOff` | Container crash — check logs below |
| `ContainerCreating` (stuck) | PVC attach or SELinux relabeling delay |
| `Multi-Attach error` in events | RWO volume still held on another node |
| No pods listed | Deployment scaled to 0 or all pods evicted |

### 2) Check ghproxy logs (if pod is Running)

```bash
oc --context "$CTX" logs -n ci deploy/ghproxy --tail=300 \
  | grep -iE 'error|fatal|panic|OOM|killed' || true
```

### 3) Identify the node and check for memory pressure

```bash
NODE=$(oc --context "$CTX" get pods -n ci -l app=prow,component=ghproxy \
  -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
echo "ghproxy node: $NODE"

# Check node conditions
oc --context "$CTX" describe node "$NODE" | grep -A5 'Conditions:'
```

If the node shows `MemoryPressure=True`, cordon it to prevent further
scheduling there:

```bash
oc --context "$CTX" cordon "$NODE"
```

### 4) Check PVC status

```bash
oc --context "$CTX" get pvc ghproxy -n ci -o wide
oc --context "$CTX" describe pvc ghproxy -n ci
```

## Recovery — escalation steps

Work through these steps in order. Move to the next step only when the
current one cannot resolve the issue.

---

### Step 1 — Simple rollout restart (pod is Running but unhealthy)

If the pod is `Running` but ghproxy is not serving (liveness probe failing,
elevated errors), restart the deployment:

```bash
oc --context "$CTX" rollout restart deploy/ghproxy -n ci
oc --context "$CTX" rollout status deploy/ghproxy -n ci --timeout=120s
```

---

### Step 2 — Clear cache from inside the pod

If the pod is Running but struggling (slow startup, high memory), exec in
and remove stale cache directories, then restart:

```bash
# List cache contents
oc --context "$CTX" exec -n ci deploy/ghproxy -- ls -lah /cache/

# Remove old cache data
oc --context "$CTX" exec -n ci deploy/ghproxy -- \
  sh -c 'rm -rf /cache/*'

# Restart to pick up a clean cache
oc --context "$CTX" rollout restart deploy/ghproxy -n ci
oc --context "$CTX" rollout status deploy/ghproxy -n ci --timeout=120s
```

---

### Step 3 — PVC stuck (Multi-Attach or SELinux relabeling)

If the pod is stuck in `ContainerCreating` and you **cannot exec** into it,
the PVC is likely blocked. Scale down, clean lingering pods, launch a
lightweight cleanup pod, then scale back up.

```bash
# Scale down deployment
oc --context "$CTX" scale deploy/ghproxy -n ci --replicas=0

# Delete any lingering ghproxy pods
oc --context "$CTX" delete pods -n ci -l app=prow,component=ghproxy \
  --grace-period=0 --wait=false

# Wait for pods to terminate
oc --context "$CTX" wait --for=delete pods -n ci \
  -l app=prow,component=ghproxy --timeout=60s || true
```

Launch a temporary cleanup pod that mounts the PVC and wipes the cache:

```bash
oc --context "$CTX" run ghproxy-cache-cleanup -n ci \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "ghproxy-cache-cleanup",
        "image": "registry.access.redhat.com/ubi9/ubi-minimal:latest",
        "command": ["sh", "-c", "rm -rf /cache/* && echo done"],
        "volumeMounts": [{
          "name": "cache",
          "mountPath": "/cache"
        }]
      }],
      "volumes": [{
        "name": "cache",
        "persistentVolumeClaim": {
          "claimName": "ghproxy"
        }
      }]
    }
  }' \
  -- sh -c 'rm -rf /cache/* && echo done'

# Wait for the cleanup pod to finish
oc --context "$CTX" wait pod/ghproxy-cache-cleanup -n ci \
  --for=condition=Ready --timeout=120s || true
oc --context "$CTX" logs -n ci ghproxy-cache-cleanup

# Remove the cleanup pod
oc --context "$CTX" delete pod ghproxy-cache-cleanup -n ci

# Scale back up
oc --context "$CTX" scale deploy/ghproxy -n ci --replicas=1
oc --context "$CTX" rollout status deploy/ghproxy -n ci --timeout=180s
```

---

### Step 4 — Cleanup pod also cannot attach the PVC

If the cleanup pod is also stuck in `ContainerCreating` with a
`Multi-Attach` error, there are **lingering pods on other nodes** that
still hold the PVC claim. Force-delete every `Succeeded` or `Failed`
ghproxy pod:

```bash
# Find all ghproxy pods across all states
oc --context "$CTX" get pods -n ci -l app=prow,component=ghproxy \
  -o wide --show-all 2>/dev/null || \
oc --context "$CTX" get pods -n ci -l app=prow,component=ghproxy -o wide

# Force-delete pods stuck in Failed / Succeeded state
oc --context "$CTX" delete pods -n ci -l app=prow,component=ghproxy \
  --field-selector=status.phase!=Running \
  --grace-period=0 --force

# Also delete the stuck cleanup pod
oc --context "$CTX" delete pod ghproxy-cache-cleanup -n ci \
  --grace-period=0 --force 2>/dev/null || true

# Wait a minute for the PVC attachment to release, then retry Step 3
```

After force-deleting, wait ~60 seconds for the volume detach to propagate,
then retry Step 3 from the cleanup-pod launch.

---

### Step 5 — Last resort: delete and recreate the PVC

If no amount of pod cleanup frees the PVC, delete it entirely and
recreate it. **This permanently wipes the cache** (which is safe — it
will repopulate from live GitHub API calls).

```bash
# Scale down
oc --context "$CTX" scale deploy/ghproxy -n ci --replicas=0

# Force-delete every ghproxy pod
oc --context "$CTX" delete pods -n ci -l app=prow,component=ghproxy \
  --grace-period=0 --force

# Delete the PVC (patch finalizer if stuck on pvc-protection)
oc --context "$CTX" delete pvc ghproxy -n ci --wait=false
oc --context "$CTX" patch pvc ghproxy -n ci -p '{"metadata":{"finalizers":null}}' \
  --type=merge 2>/dev/null || true
oc --context "$CTX" wait --for=delete pvc/ghproxy -n ci --timeout=60s || true

# Recreate the PVC
oc --context "$CTX" apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  labels:
    app: prow
    component: ghproxy
  name: ghproxy
  namespace: ci
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 30Gi
  storageClassName: gp2
  volumeMode: Filesystem
EOF

# Scale back up
oc --context "$CTX" scale deploy/ghproxy -n ci --replicas=1
oc --context "$CTX" rollout status deploy/ghproxy -n ci --timeout=180s
```

> **Note:** The recreated PVC will get a new PV. The old `volumeName`
> binding in the deployment YAML (if any) is not required — dynamic
> provisioning assigns a fresh volume.

## Verify recovery

```bash
# Pod should be Running and Ready
oc --context "$CTX" get pods -n ci -l app=prow,component=ghproxy -o wide

# Health endpoint should return 200
oc --context "$CTX" exec -n ci deploy/ghproxy -- \
  wget -qO- http://localhost:8081/healthz/ready

# Metrics endpoint should be reachable
oc --context "$CTX" exec -n ci deploy/ghproxy -- \
  wget -qO- http://localhost:9090/metrics | head -5
```

The **SHIP Status Dashboard** outage indicator auto-clears once the
component monitor detects `max(up{job="ghproxy"}) > 0`.

## Follow-up actions

1. If a node was cordoned for memory pressure, investigate the root cause
   and uncordon once resolved:
   ```bash
   oc --context "$CTX" uncordon "$NODE"
   ```
2. Check whether the eviction was caused by another pod on the same node
   consuming excessive memory.
3. If SELinux relabeling delays recur, consider filing a bug for
   persistent cache directory cleanup in the ghproxy container entrypoint.
4. Review node memory utilisation trends to determine if ghproxy needs a
   memory limit or should be moved to a dedicated node pool.
5. If the PVC had to be recreated, open a PR to remove the stale
   `volumeName` binding from
   [`ghproxy.yaml`](../../clusters/app.ci/prow/03_deployment/ghproxy.yaml)
   (if present) so future PVC recreation works without manual patching.
