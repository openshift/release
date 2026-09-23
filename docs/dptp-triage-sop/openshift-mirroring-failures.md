# OpenShift Mirroring Failures

## Alert binding

| Field | Value |
|-------|-------|
| **Alert** | `openshift-mirroring-failures` |
| **Cluster** | `app.ci` |
| **Rules** | [`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml) — group `openshift-mirroring-failures` |
| **Severity** | `critical` |

This SOP covers the `openshift-mirroring-failures` alert on `app.ci`.

## What this alert means

This alert fires when OpenShift image-mirroring jobs have no successful run in the configured time window.
In practice, this means we are seeing a series of failures and need to restore at least one successful run.

## Primary goal

Get one successful run of `periodic-image-mirroring-openshift` after the failure streak.

The exact fix depends on the failure type, but the path to recovery is usually fixing image-related errors (for example `manifest unknown`, missing tags/digests, or invalid manifests), then rerunning or waiting for the next periodic run.

## Triage

1. Open the failing job history:
   - <https://prow.ci.openshift.org/?job=periodic-image-mirroring-openshift>
2. Confirm repeated failures and identify the latest failure log.
3. Extract the first concrete error from `oc image mirror` output.
4. Analyze the failure:
   - Source image problem (`manifest unknown`, missing image/tag, bad digest)
   - Destination push/auth problem (permission denied, auth/credentials)
   - Registry/network/transient problem (timeouts, temporary API failures)
5. Apply the minimal fix needed to get a successful run.

## Diagnose with `oc` on `app.ci`

### 1) List recent ProwJobs for the periodic

Job name in Deck/Prow: **`periodic-image-mirroring-openshift`**.

```bash
CTX=app.ci

oc --context "$CTX" get prowjobs.prow.k8s.io -n ci \
  --sort-by=.metadata.creationTimestamp \
  | { grep periodic-image-mirroring-openshift || true; } | tail -10
```

Pick the newest **`STATE=failure`** row’s **`NAME`**.

### 2) Inspect ProwJob status (URLs, finish time)

```bash
PJ=<name-from-previous-command>

oc --context "$CTX" get prowjob.prow.k8s.io -n ci "$PJ" -o yaml | sed -n '1,120p'
```

Note **`status.url`** (artifact browser) and **`status.build_id`**.

### 3) Find runner pods (while still retained)

```bash
BUILD_ID=<status.build_id>

oc --context "$CTX" get pods --all-namespaces \
  -l prow.k8s.io/build-id="$BUILD_ID" \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase'
```

Typical mirror workload namespaces begin with **`ci-op-`** or stay in **`ci`** depending on agent—use **`NS`** from the row whose **`NAME`** references **`image-mirroring`** / **`ci-operator`**.

### 4) Stream ci-operator / test logs locally

```bash
TEST_NS=<namespace-from-above>
OPERATOR_POD=$(oc --context "$CTX" get pods -n "$TEST_NS" -o name | grep ci-operator | head -1 | sed 's|pod/||')

oc --context "$CTX" logs -n "$TEST_NS" "$OPERATOR_POD" -c test --tail=400 \
  | grep -iE 'image mirror|manifest unknown|unauthorized|FORBIDDEN|error:|level=error' || true
```

### 5) If pods already GC’d

Fall back to **GCS artifact path** from **`status.url`** (same content as CI Search would index).

## Common recovery actions

- Fix or rebuild broken source images, usually by rerunning related postsubmit(s).
- If transient, retrigger and verify the next run succeeds.

## Success criteria

- At least one successful `periodic-image-mirroring-openshift` run is observed in Prow.
- The alert resolves after success is recorded.

