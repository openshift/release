# Prow Job State Pileup

## Alert binding

| Field | Value |
|-------|-------|
| **Alerts** | `TriggeredProwJobsPileup`, `SchedulingProwJobsPileup` |
| **Cluster** | `app.ci` |
| **Rules** | [`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml) — `prow` group; definitions in [`prow_alerts.libsonnet`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/_prometheus/prow_alerts.libsonnet) |
| **Thresholds** | **Triggered**: `max_over_time(sum(prowjobs{job="prow-controller-manager",state="triggered"})[5m:]) > 450`. **Scheduling**: same with **`state="scheduling"`**, threshold **`300`**. |
| **Severity** | `Triggered…` **critical**, `Scheduling…` **warning** |
| **Related** | Build farm Pending / pressure — [`build-farm-scheduling-pressure.md`](build-farm-scheduling-pressure.md). |

## What “pileup” means

**`triggered`**: jobs accepted by Prow but not yet running—often backlog before scheduling assigns a cluster.

**`scheduling`**: jobs assigned/placed into scheduling state but not yet fully running pods—often overlaps with build-farm capacity / plank concurrency pressure.

## Prerequisites

- **`oc`** access to **`app.ci`** (`ci` namespace hosts **`prow-controller-manager`**, **`sinker`**, **`deck`**, etc.).
- Grafana **Plank dashboard** link from runbook steps below.

## Diagnose on-cluster (`app.ci`)

### 1) Controller health and recent restarts

```bash
CTX=app.ci

oc --context "$CTX" get deploy -n ci prow-controller-manager sinker deck tide horologium
oc --context "$CTX" get pods -n ci -l 'app=prow,component=prow-controller-manager' -o wide
oc --context "$CTX" logs -n ci deploy/prow-controller-manager --tail=200 \
  | grep -iE 'error|fail|backoff' || true
```

### 2) Workqueue depth (matches related alert pattern)

**Prometheus stack:** Prow metrics used by these alerts (including **`workqueue_depth`** and **`prowjobs{job="prow-controller-manager",…}`**) are scraped into **user workload monitoring** on **app.ci**—PrometheusRules live under [`openshift-user-workload-monitoring`](../../clusters/app.ci/openshift-user-workload-monitoring/). Use **Administrator → Observe → Metrics** on the cluster console, not only platform monitoring, when a query returns empty.

**Query:** PromQL **`workqueue_depth{name=~"crier.*|plank"}`** — [pre-filled Query browser on app.ci](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/query-browser?query0=workqueue_depth%7Bname%3D~%22crier.*%7Cplank%22%7D).

**Alert rule:** [`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml) — alert **`Controller backlog is not being drained`** (`workqueue_depth{name=~"crier.*|plank"} > 100`).

**On-cluster targets:** **`plank`** runs inside **`deploy/prow-controller-manager`** when enabled (**`--enable-controller=plank`** in [`prow-controller-manager.yaml`](../../clusters/app.ci/prow/03_deployment/prow-controller-manager.yaml)); **`crier`** is **`deploy/crier`**. For **`workqueue_depth`** series whose **`name`** matches **`plank`**, follow **`prow-controller-manager`** logs (§1); for **`crier.*`**, follow **`crier`** logs.

If **`workqueue_depth`** stays **>100** for **`plank`** / **`crier`** for **~20m**, treat as controller backlog not draining; gather **`prow-controller-manager`** and **`crier`** logs from the same window.

### 3) Count triggered vs scheduling jobs (Prometheus)

Use Grafana panel **“Number of Prow jobs by state with cluster”** on [Plank dashboard](https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/e1778910572e3552a935c2035ce80369/plank-dashboard).

Raw inspect (Console Prometheus on **`app.ci`**):

```promql
sum(prowjobs{job="prow-controller-manager", state="triggered"})
sum(prowjobs{job="prow-controller-manager", state="scheduling"})
```

Confirm values breach rule thresholds above during the incident window.

### 4) Pending / unscheduled jobs (symptom → build farms)

If **`scheduling`** dominates, follow [`build-farm-scheduling-pressure.md`](build-farm-scheduling-pressure.md) **per build cluster**—Pending pods in **`ci`** namespace drive plank slots.

### 5) GitHub / hook saturation (when `triggered` grows)

If **`hook`** or **`ghproxy`** incidents coincide, check:

```bash
oc --context "$CTX" get pods -n ci -l 'component in (hook,ghproxy)' -o wide
oc --context "$CTX" logs -n ci deploy/hook --tail=150
oc --context "$CTX" logs -n ci deploy/ghproxy --tail=150
```

Cross-reference [`ghproxy-too-many-pending-alerts.md`](ghproxy-too-many-pending-alerts.md).

## Configuration knobs (read-only triage first)

- **`max_concurrency`** (global running job cap): [`core-services/prow/02_config/_config.yaml`](https://github.com/openshift/release/blob/main/core-services/prow/02_config/_config.yaml).
- **Per-repo burst limits** live under same Prow config tree—coordinate changes via **`openshift/release`** PR; do **not** hot-edit production without process.

## Fix patterns

1. **Build farm capacity**: relieve Pending / node pressure (autoscaler, MachineSets) per build-farm SOP.
2. **Stuck controller**: restart **only** after two operators agree—capture logs first:

   ```bash
   oc --context app.ci rollout restart deploy/prow-controller-manager -n ci
   oc --context app.ci rollout status deploy/prow-controller-manager -n ci
   ```

3. **External dependency** (GitHub outage): wait / reduce trigger volume—communicate in **`#ops-testplatform`**.
4. **Bad config change**: revert offending Prow **`ConfigMap`** / **`Horologium`** periodic only via normal GitOps flow.

## Verify

- Grafana: **`triggered`** / **`scheduling`** counts fall below historical baseline and alert clears.
- **`workqueue_depth`** returns to normal.

## Escalation

Sustained pileup with **merge queue impact** → **`@dptp-triage`** with Grafana screenshots + **`oc`** logs bundle (`prow-controller-manager`, `sinker`, build-farm Pending snapshot).
