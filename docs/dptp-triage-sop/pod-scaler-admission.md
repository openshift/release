# pod-scaler admission resource warning

## Alert binding

| Field | Value |
|-------|-------|
| **Alert** | `pod-scaler-admission-resource-warning` |
| **Cluster** | `app.ci` |
| **Rules** | [`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml) — group `pod-scaler-admission-resource-warning` |
| **Severity** | `critical` |

This alert fires when **pod-scaler admission** observes a workload using roughly **10×** the **CPU or memory** declared in CI configuration—usually wrong limits, a leak, or an undersized declaration. **Do not** scale cluster capacity as the first response; notify **job/config owners**.

## Prerequisites

- **`rg` (ripgrep)** on **`PATH`** for **Diagnose §5** (`rg -n 'resources:' ci-operator/config/<org>/<repo>/`). Install via OS package (**`dnf install ripgrep`**, **`apt install ripgrep`**, **`brew install ripgrep`**) or [upstream releases](https://github.com/BurntSushi/ripgrep/releases).

## Labels you need from Slack / Prometheus

From the alert or [this Console query](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/query-browser?query0=sum+by+%28workload_name%2C+workload_type%2C+determined_amount%2C+configured_amount%2C+resource_type%29+%28pod_scaler_admission_high_determined_resource%7Bworkload_type%21%7E%22undefined%7Cbuild%22%7D%29):

| Label | Meaning |
|-------|---------|
| **`workload_name`** | `<pod>-<container>` fingerprint admission saw |
| **`workload_type`** | `step`, `prowjob`, … (`build` alerts filtered out of rule) |
| **`resource_type`** | `cpu` or `memory` |
| **`determined_amount`** / **`configured_amount`** | Observed vs declared signal |

## Diagnose

### 1) Confirm pod-scaler components are up

Pod scaler runs in **`ci`** ([`pod-scaler.yaml`](../../clusters/app.ci/pod-scaler/pod-scaler.yaml), [`pod-scaler-ui.yaml`](../../clusters/app.ci/pod-scaler/pod-scaler-ui.yaml)):

```bash
CTX=app.ci

oc --context "$CTX" get deploy -n ci pod-scaler-producer pod-scaler-ui
oc --context "$CTX" get pods -n ci -l 'component in (pod-scaler-producer,pod-scaler-ui)' -o wide
```

If **`pod-scaler-producer`** is unhealthy, fix it **before** blaming workloads—see alerts **`pod-scaler-producer-Singleton-Down`** / **`pod-scaler-ui-Down`**.

### 2) Capture admission / producer logs around the timestamp

```bash
oc --context "$CTX" logs -n ci deploy/pod-scaler-producer --since=30m --tail=400 \
  | grep -iE 'admission|high_determined|workload' || true
```

### 3) Map `workload_type=prowjob` → ProwJob object

```bash
# If workload_name looks like mypod-ci-operator — extract prowjob name from CI / Deck instead:
PJ=<prowjob-name-from-deck>

oc --context "$CTX" get prowjob.prow.k8s.io -n ci "$PJ" -o yaml
```

Look under **`spec`** for **`refs.org`**, **`refs.repo`**, **`refs.pulls`**, **`job`**.

### 4) Map `workload_type=step` → ci-operator config namespace

Use **`prow.k8s.io/build-id`** from Deck URL:

```bash
BUILD_ID=<digits>
CTX=app.ci

oc --context "$CTX" get pods --all-namespaces \
  -l prow.k8s.io/build-id="$BUILD_ID" \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name'
```

Open **`TEST_NS=ci-op-*`**, describe the pod referenced by **`workload_name`** prefix:

```bash
TEST_NS=<ci-op-xxxx>
POD_PREFIX=<pod prefix before first '-' if needed>

oc --context "$CTX" get pods -n "$TEST_NS"
oc --context "$CTX" describe pod -n "$TEST_NS" <exact-pod-name>
```

Check **`requests`/`limits`** on the container named after **`workload_name`** suffix.

### 5) Compare with declared CI resources

Locate **`ci-operator`** configuration in **`openshift/release`**:

```bash
# From repo root — replace repo/component
rg -n 'resources:' ci-operator/config/<org>/<repo>/ | head
```

Owners should align **`requests`/`limits`** with **`pod-scaler`** recommendations or justify outliers.

## Fix

1. **Repo owners** update **`ci-operator`** config (memory/CPU requests & limits) or fix leaks in tests/builds.
2. **No cluster mutation** unless producers are broken—escalate bad **`pod-scaler`** behavior separately.
3. After merge, watch **`pod_scaler_admission_high_determined_resource`** time series for that workload disappear.

## Verify

- Alert clears after workloads roll with new resource declarations.
- Optional: re-query Prometheus for label set **`workload_name="…"`** — should be absent post-fix.

## Escalation

If **`pod-scaler-producer`** is healthy but admissions look clearly wrong (false positives), **`@dptp-triage`** with **metric snapshot**, **ProwJob** link, and **pod describe** output.
