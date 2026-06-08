# High CI Operator Infra Error Rate

## Alert binding

| Field | Value |
|-------|-------|
| **Alert** | `high-ci-operator-infra-error-rate` |
| **Cluster** | `app.ci` (user workload monitoring) |
| **Rule group** | `ci-operator-infra-error` in [`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml) |
| **Severity** | `critical` |
| **Related** | [`high-ci-operator-error-rate.md`](high-ci-operator-error-rate.md) — non-infra variant (higher rate threshold, no multi-job correlation). Slack text for this alert may omit an SOP URL; use this document whenever the alert name matches. |

## What this alert means

The rule keeps failing CI Operator executions for one **`reason`** above **0.02/s** (30m rate) **only if** that **`reason`** appears across **≥3** distinct **`job_name`** values (excluding rehearses). That pattern targets **shared infrastructure** regressions rather than a single repo flake.

## Prerequisites

- **`oc`** with a context that can read **`app.ci`** (and **build-farm** contexts if failures reference those clusters). Replace **`app.ci`** below if your kubeconfig uses another context name.
- **Labels from Slack**: note **`reason`** (and any **`job_name`** / **`cluster`** hints embedded in CI Search links).

## Common `reason` values

(See [`dptp_alerts.libsonnet`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/_prometheus/dptp_alerts.libsonnet) — rule `high-ci-operator-infra-error-rate`.)

- `executing_graph:step_failed:creating_release_images`
- `executing_graph:step_failed:tagging_input_image`
- `executing_graph:step_failed:building_project_image:pod_pending`
- `executing_graph:step_failed:utilizing_cluster_claim:acquiring_cluster_claim`
- `executing_graph:step_failed:importing_release`

## Diagnose (repeat per dominant `reason`)

### 1) Confirm breadth (matches “infra” intent)

1. Open **CI Search** from the alert (pre-filled `Reporting job state` / `reason`).
2. In the incident window, confirm **multiple distinct `job_name` values** fail with the same **`reason`** (the Prometheus rule requires ≥3 jobs).
3. Note **one representative `job_name`**, **build ID** (from Deck / Prow URL), and **cluster** (build farm name or `app.ci`).

### 2) Map build → namespaces and pods on `app.ci`

ProwJobs live in namespace **`ci`**. Test workloads run in ephemeral **`ci-op-*`** namespaces (and pods carry **`prow.k8s.io/build-id`**).

**`JOB_NAME`** for **`oc get prowjob.prow.k8s.io … "$JOB_NAME"`** must be the **`ProwJob` object’s `metadata.name`** (Kubernetes resource name), **not** **`spec.job`** (the human-readable string behind Deck’s **`job=`** filter) and **not** the numeric **`BUILD_ID`** from the artifact URL. If you only have **`spec.job`** or **`BUILD_ID`**, resolve **`metadata.name`** first:

```bash
CTX=app.ci

# Option A — you already have metadata.name (from kubectl/oc columns NAME, or copied from API):
JOB_NAME=<metadata.name>

# Option B — only spec.job / Deck job= string (may match multiple runs; newest last):
SPEC_JOB=<spec.job value>
JOB_NAME=$(oc --context "$CTX" get prowjobs.prow.k8s.io -n ci \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{range .items[*]}{.spec.job}{"\t"}{.metadata.name}{"\n"}{end}' \
  | awk -F'\t' -v j="$SPEC_JOB" '$1 == j {print $2}' | tail -1)

# Option C — only BUILD_ID (matches status.build_id on the ProwJob):
BUILD_ID=<digits-from-deck-url>
JOB_NAME=$(oc --context "$CTX" get prowjobs.prow.k8s.io -n ci \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{range .items[*]}{.status.build_id}{"\t"}{.metadata.name}{"\n"}{end}' \
  | awk -F'\t' -v b="$BUILD_ID" '$1 == b {print $2}' | tail -1)

oc --context "$CTX" get prowjob.prow.k8s.io -n ci "$JOB_NAME" -o yaml
```

Extract **build ID** from the Deck URL (`…/view/gs/origin-ci-test/pr-logs/pull/…/<BUILD_ID>/…`) or from **`status.build_id`** / labels:

```bash
BUILD_ID=<digits-from-deck-url>

oc --context "$CTX" get pods --all-namespaces \
  -l prow.k8s.io/build-id="$BUILD_ID" \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase'
```

Identify the row whose namespace matches **`ci-op-*`** (that is the ci-operator test namespace). Then:

```bash
TEST_NS=<ci-op-xxxxxxxx>
oc --context "$CTX" get pods -n "$TEST_NS" -o wide
```

Find the **`ci-operator`** pod (name prefix often `ci-operator-*`):

```bash
OP_POD=$(oc --context "$CTX" get pods -n "$TEST_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E '^ci-operator-' | head -1)
echo "$OP_POD"
```

### 3) Pull ci-operator logs for the failure signature

```bash
oc --context "$CTX" logs -n "$TEST_NS" "$OP_POD" -c test --tail=800 \
  | grep -E 'Reporting job state|step_failed|level=error|reason=' || true
```

Narrow to the alert **`reason`** string:

```bash
REASON='<paste exact reason from alert labels>'
oc --context "$CTX" logs -n "$TEST_NS" "$OP_POD" -c test --tail=2000 \
  | grep -F "$REASON" | tail -50
```

### 4) If the failure references image pulls / release payloads

On a workstation with pull access (or from a debug pod—follow org policy), image checks help distinguish **missing tag** vs **registry outage**:

```bash
# Example only — replace with image reference from the log line
oc image info registry.ci.openshift.org/ocp/release@sha256:...
```

If many jobs fail `importing_release` / `creating_release_images`, escalate toward **release/registry** paths and cross-check [`openshift-mirroring-failures.md`](openshift-mirroring-failures.md) / [`misc.md`](misc.md) (`quay-io-image-mirroring-failures`).

### 5) If `reason` ends with `:pod_pending` or mentions scheduling

Run on the **cluster where the test pod should land** (often a **buildNN** context):

```bash
BF=build01   # or build02, … per failure output

oc --context "$BF" get pods -n ci --field-selector=status.phase=Pending --no-headers | wc -l
oc --context "$BF" get events -n ci --sort-by=.lastTimestamp | tail -30
```

Follow [`build-farm-scheduling-pressure.md`](build-farm-scheduling-pressure.md) if Pending counts / `FailedScheduling` dominate.

### 6) If `reason` contains `acquiring_cluster_claim` / lease

Treat as **Hive / pool / quota** pressure in addition to ci-operator logs:

```bash
oc --context hosted-mgmt get clusterclaims -n ci-cluster-pool --sort-by=.metadata.creationTimestamp | tail
```

(Adjust pool namespace if your alert references a different pool—see Hive runbooks.)

## Fix / mitigate

1. **Registry / image / release payload**: restore image promotion or fix broken image job (often repo-specific); use **`make job JOB=…`** from a clean **`openshift/release`** checkout only when you intend to re-run the producing job—see patterns in [`misc.md`](misc.md).
2. **Scheduling / capacity**: scale MachineSets / fix autoscaler / relieve taints per build-farm SOP—not `app.ci` mutations unless the workload truly runs on `app.ci`.
3. **Cluster claims / leases**: free stuck claims, expand pool, or fix cloud-side deletion blockers per Hive / cloud owner process.
4. **Transient GitHub / API**: retry failed jobs after upstream recovery; confirm error rate falls in Prometheus.

After mitigation:

```bash
# Example: rate should fall below rule threshold for that reason
# (run in OpenShift console Prometheus UI on app.ci user workload stack)
```

## Escalation

If merges or release pipelines stall broadly, notify **`@dptp-triage`** with **CI Search links**, dominant **`reason`**, **`BUILD_ID`**, **`TEST_NS`**, and clusters impacted.
