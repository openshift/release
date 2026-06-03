# High CI Operator Error Rate

## Alert binding

| Field | Value |
|-------|-------|
| **Alert** | `high-ci-operator-error-rate` |
| **Cluster** | `app.ci` |
| **Rule group** | `ci-operator-error` in [`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml) |
| **Severity** | `critical` |
| **Related** | [`high-ci-operator-infra-error-rate.md`](high-ci-operator-infra-error-rate.md) — infra-correlated variant (multi-job gate + lower rate threshold). |

## What this alert means

This alert fires when failed CI Operator executions exceed **0.08/s** (30m rate) for a specific **`reason`** label on **`ci_operator_error_rate`**. It **does not** require multiple jobs—single-repo storms can page. Treat sustained repeats as higher urgency than one short spike.

## Prerequisites

- **`oc`** context for **`app.ci`** and any **build-farm** cluster referenced in failing jobs.
- Slack / Alert labels: capture **`reason`** and CI Search URL.

## Most common reasons

### `executing_graph:step_failed:building_project_image`

Project image build step failed in the ci-operator graph (Dockerfile, inputs, registry pull/push, cluster build).

### `executing_graph:interrupted`

Graph stopped due to cancel/interrupt (human cancel, infra churn, namespace teardown), not a failed test assertion.

## Diagnose

### 1) Quantify blast radius

1. Open **CI Search** from the alert (`reason` in query).
2. Bucket failures by **`job_name`**, repo, **cluster**, and time—answer: **one repo** vs **many**.
3. If **many jobs / clusters** share the same **`reason`**, treat like an infra incident and also read [`high-ci-operator-infra-error-rate.md`](high-ci-operator-infra-error-rate.md).

### 2) Pick one failing ProwJob and resolve build metadata

```bash
CTX=app.ci
JOB_NAME=<prowjob.metadata.name>

oc --context "$CTX" get prowjob.prow.k8s.io -n ci "$JOB_NAME" \
  -o custom-columns='STATE:.status.state,JOB:.spec.job,URL:.status.url'
```

### 3) Locate ci-operator pod via `prow.k8s.io/build-id`

```bash
BUILD_ID=<from Deck URL>

oc --context "$CTX" get pods --all-namespaces \
  -l prow.k8s.io/build-id="$BUILD_ID" \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase'
```

Pick **`TEST_NS=ci-op-*`**. List containers:

```bash
TEST_NS=<ci-op-xxxxxxxx>
oc --context "$CTX" get pods -n "$TEST_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
```

### 4) Logs — ci-operator (`test` container)

```bash
OP_POD=$(oc --context "$CTX" get pods -n "$TEST_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E '^ci-operator-' | head -1)

if [[ -z "$OP_POD" ]]; then
  echo "No ci-operator-* pod in ${TEST_NS}; use GCS artifacts from the ProwJob status.url / Deck build."
else
  oc --context "$CTX" logs -n "$TEST_NS" "$OP_POD" -c test --tail=1500 \
    | grep -E 'Reporting job state|step_failed|building_project_image|interrupted|level=error' | tail -80
fi
```

### 5) Logs — failing build / test pod

From the same namespace, identify **`build`/`src`/`test`** pods referenced in ci-operator output:

```bash
oc --context "$CTX" get pods -n "$TEST_NS"
oc --context "$CTX" describe pod -n "$TEST_NS" <suspect-pod>
oc --context "$CTX" logs -n "$TEST_NS" <suspect-pod> -c <container> --tail=400
```

### 6) Events (scheduling, mounts, OOM)

```bash
oc --context "$CTX" get events -n "$TEST_NS" --sort-by=.lastTimestamp | tail -40
```

## Fix / mitigate

### `building_project_image`

1. Fix **Dockerfile / inputs** or **base image** per log—often repo-owned.
2. For **registry flakes**, verify **`registry.ci.openshift.org`** / mirror health; compare with other jobs pulling same image.
3. Re-run **after** fix: prefer **`/retest`** or Prow **rerun** from Deck rather than ad-hoc cluster tweaks.

### `interrupted`

1. Check **whether namespace disappeared early** (`Terminating`, quota, cluster instability).
2. Correlate with **apiserver / node** events on the execution cluster context.
3. If mass interrupts during **platform maintenance**, silence/route per policy—not job-by-job kills.

## Verify

- CI Search shows **falling failure rate** for the same **`reason`** window-over-window.
- Spot-check one replayed job reaches **`success`** state:

```bash
oc --context app.ci get prowjob.prow.k8s.io -n ci "$JOB_NAME" -o jsonpath='{.status.state}{"\n"}'
```

## Escalation

Ping **`@dptp-triage`** when **`reason`** trend blocks merging across repositories or multiple clusters show identical failures without an obvious repo-owned fix.
