---
name: loki
description: Use this skill to analyze failing CI tests for the OpenShift Loki Operator (LokiStack, gateway, distributor, ingester, querier, ruler, compactor, index-gateway), rerun the specific failing tests (Ginkgo/openshift-tests-extension, junit_openshift_logging_e2e_tests_loki_operator prefix), diagnose whether the failure is a product bug or a test that needs fixing, apply fixes to test source files when needed, and export results to the artifact directory. Trigger whenever $SHARED_DIR/qe-agent-context.json is present with has_test_failures=true for loki-operator PRGate tests, or when an engineer asks to debug, rerun, or fix failing loki QE tests.
---

# Loki Operator QE Agent — Test Failure Triage and Fix

This skill drives an agentic loop that takes failing CI test results for the Loki Operator PRGate suite, reruns the failing tests, determines root cause (product bug vs broken test), and either fixes the test or writes a structured bug report.

## Test Infrastructure Overview

| JUnit prefix | Suite | Framework | Repo |
|---|---|---|---|
| `junit_openshift_logging_e2e_tests_loki_operator` | loki-operator PRGate | Ginkgo via openshift-tests-extension | `https://github.com/openshift-eng/openshift-logging-e2e-tests` |

## Step 0 — Read Setup Context and Fetch the Step Script

Read `${SHARED_DIR}/qe-agent-context.json`. The test step writes it at exit time:

```json
{
  "step_script_ref": "openshift-observability/logging-e2e-tests/openshift-observability-logging-e2e-tests-commands.sh",
  "has_test_failures": true,
  "env": {
    "TEST_SUITE": "openshift-logging-e2e-tests/loki-operator"
  }
}
```

Fetch `https://raw.githubusercontent.com/openshift/release/main/ci-operator/step-registry/<step_script_ref>` for reference — this script is short (proxy setup, `HOME` export, `unset NAMESPACE`, then `run-suite`) and needs no adaptation; there is no repo clone or build to replay.

## Step 0a — Verify Cluster Stability

Mandatory, before Step 0b. Read `/tmp/qe-agent-modules/cluster-stability.md` and follow it. If missing: poll `oc get machineconfigpools.machineconfiguration.openshift.io` every 60s for up to 20 minutes until every pool is `UPDATED=True`, `UPDATING=False`, `DEGRADED=False`; if pools are listed but never become ready, classify `CLUSTER_INSTABILITY` (Step 5d) and skip to Step 6; if the query itself keeps failing, record the MCP status as unavailable, recommend a rerun and skip to Step 6.

## Step 0b — Re-establish the Test Environment

The extension binary `openshift-logging-e2e-tests-tests-ext` is already on `PATH` in this pod's image (same base image as the test step). There is no repo to clone and no build step. Required adaptation from the fetched script:

| Script pattern | Adaptation |
|---|---|
| `export HOME=/tmp/home; mkdir -p "${HOME}"` | Run this first — the framework writes kubeconfig copies and temp files under `HOME`, which is not writable for this pod's UID otherwise |
| `unset NAMESPACE` | Run this before any test invocation — a set `NAMESPACE` (ci-operator's build-farm namespace) causes `oc process` calls without an explicit `-n` to resolve against the wrong namespace |
| Cluster-logging-operator, loki-operator installation | Already done by prior CI steps (`install`, `install-operators`) — do not reinstall |

No further setup is needed; proceed directly to Steps 1–6.

## Step 1 — Parse JUnit XMLs and Identify Failures

Mandatory. Read `/tmp/qe-agent-modules/junit-triage.md` and follow it. Typical shared root causes here: operator crash, missing CRD, storage backend unavailable, cluster resource contention. If missing: read `${SHARED_DIR}/qe-agent-junit-*.xml`, extract each suite name and failed `<testcase>` (`<failure>`/`<error>` message and full text), group by suite, and exit with a clear message if there are no files. If more than 5 tests fail, look for one shared root cause and diagnose the simplest failing test as the representative (Steps 2–5); with no pattern, diagnose individually, capped at 3. Write any pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.

Failure messages include the `file:line` they cite. Test names follow the pattern `[sig-openshift-logging] Logging ... Author:<user>-<Importance>-<case-id>-<description>[PRGate][LokiOperator]...` — the case ID is the numeric segment after `Author:<user>-<Importance>-`.

---

## Step 2 — Locate Test Source Files

Clone the test repo shallowly (read-only, public) to inspect source without guessing:

```bash
git clone --depth 1 https://github.com/openshift-eng/openshift-logging-e2e-tests /tmp/e2e-tests-src
```

Test implementations live under [test/e2e/loki.go](https://github.com/openshift-eng/openshift-logging-e2e-tests/blob/main/test/e2e/loki.go) and related `test/e2e/*.go` files (not one file per test). Find the failing test by its case ID or description text:

```bash
grep -rn "<case-id>" /tmp/e2e-tests-src/test/e2e/*.go
```

Shared Loki helpers live in [test/e2e/loki_utils.go](https://github.com/openshift-eng/openshift-logging-e2e-tests/blob/main/test/e2e/loki_utils.go); general helpers in [test/e2e/utils.go](https://github.com/openshift-eng/openshift-logging-e2e-tests/blob/main/test/e2e/utils.go); fixture YAML under `test/e2e/testdata/logging/lokistack/`. Record the file and approximate line range as `TEST_SRC`.

---

## Step 3 — Rerun the Failing Tests

Rerun only the specific failing test(s), not the entire suite.

```bash
export HOME=/tmp/home
unset NAMESPACE
openshift-logging-e2e-tests-tests-ext list tests --suite openshift-logging-e2e-tests/loki-operator -o names | grep "<case-id>"
```

Use the exact name from that output as `TEST_NAME`, then rerun it:

```bash
export HOME=/tmp/home
unset NAMESPACE
TEST_NAME="<exact name from list output>"
openshift-logging-e2e-tests-tests-ext run-test "${TEST_NAME}" --junit-path "${ARTIFACT_DIR}/junit_rerun_loki.xml"
```

The test's own `AfterEach` (and `defer ls.removeLokiStack(oc)` / `defer ls.removeObjectStorage(oc)` in the source) cleans up its LokiStack and namespace regardless of pass/fail, so no manual cleanup is needed between runs.

After the rerun, read the fresh JUnit XML. If still failing → proceed to Step 4. If it passed → possible flakiness; run 3 more times (flakiness loop below).

### Flakiness confirmation loop

If the test passes on the first rerun, run it 3 more times sequentially with a unique `--junit-path` per run so the XMLs don't overwrite each other:

```bash
export HOME=/tmp/home
unset NAMESPACE
TEST_NAME="<exact name from list output>"
for i in 2 3 4; do
  openshift-logging-e2e-tests-tests-ext run-test "${TEST_NAME}" --junit-path "${ARTIFACT_DIR}/junit_rerun_loki_run${i}.xml"
done
```

After all 4 runs, count how many passed vs failed. Record the pass/fail pattern (e.g., `PFPP`) and proceed to Step 4 for diagnosis in every case — including when all 4 runs passed, so the Cluster Instability criteria can still be evaluated before ruling the failure not reproduced.

---

## Step 4 — Diagnose: Product Bug vs Test Issue

Read the failure message, rerun output, and test source together. Then run the diagnostics below before classifying — the logs and resource status are the primary evidence.

### Loki Operator Diagnostics

```bash
# Operator pod status and logs
oc get pods -n openshift-operators-redhat
oc logs -n openshift-operators-redhat deploy/loki-operator-controller-manager --tail=150
oc logs -n openshift-operators-redhat deploy/loki-operator-controller-manager --previous --tail=50 2>/dev/null || true

# LokiStack instances across all namespaces (excluding kube-system)
oc get lokistack --all-namespaces 2>/dev/null | grep -v kube-system
oc get lokistack --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.conditions[*].type}={.status.conditions[*].status}{"\n"}{end}' 2>/dev/null | grep -v kube-system

# Loki component pods (gateway, distributor, ingester, querier, query-frontend, compactor, ruler, index-gateway)
# in the test's own namespace (from the failing test name / JUnit context)
oc get pods -n <test-namespace> -o wide
oc describe pods -n <test-namespace> | grep -A10 -E 'Events:|Reason:|State:|Exit Code:|OOMKilled'

# Object storage secret (a very common Loki failure cause — bucket not found / credentials rejected)
oc get secret -n <test-namespace> | grep -E 'storage|minio|s3|gcs|azure'

# Events
oc get events -n openshift-operators-redhat --sort-by='.lastTimestamp' | tail -20
oc get events -n <test-namespace> --sort-by='.lastTimestamp' | tail -30

# CSV and subscription status
oc get csv -n openshift-operators-redhat -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase} — {.status.message}{"\n"}{end}'
oc get subscription -n openshift-operators-redhat -o jsonpath='{range .items[*]}{.metadata.name}: {.status.currentCSV} state={.status.state}{"\n"}{end}' 2>/dev/null || true
```

### CRD and API availability check

```bash
oc get crd | grep -E 'loki.grafana.com'
oc api-resources | grep -i lokistack
```

### Product Bug indicators
Classify as `PRODUCT_BUG` when the evidence shows the operator or a Loki component itself misbehaved:
- `loki-operator-controller-manager` pod in `CrashLoopBackOff` or `OOMKilled`
- `LokiStack` stuck in a non-Ready/non-Pending condition not caused by the test's own CR spec
- A Loki component container itself in `CrashLoopBackOff` (not `ContainerCreating`/`ImagePullBackOff` — those usually indicate cluster/environment resource contention, see Cluster Instability below)
- CRD validation error rejecting a valid `LokiStack` CR that worked in a prior release
- Genuine storage backend rejection (credentials invalid, bucket does not exist) rather than the bucket simply not yet having ingested data

### Test Issue indicators
Classify as `TEST_ISSUE` when the test itself is wrong, not the product. Check the failing test's source (and its helpers in [test/e2e/loki_utils.go](https://github.com/openshift-eng/openshift-logging-e2e-tests/blob/main/test/e2e/loki_utils.go), [test/e2e/utils.go](https://github.com/openshift-eng/openshift-logging-e2e-tests/blob/main/test/e2e/utils.go)) for these patterns:
- A template-processing call (`oc process`, or this repo's `processTemplate(oc, ...)` helper) without an explicit `-n <namespace>` — falls back to whatever namespace the ambient kubeconfig context resolves to, which may not exist on the target cluster; look for "error processing file" or a "namespaces ... not found" error unrelated to the resource under test
- A `List`/`Get` label selector scoped only by a generic label (`app.kubernetes.io/component=<x>`) without a per-instance label (`app.kubernetes.io/instance=<lokistack-name>`) in a namespace shared across tests (e.g. `openshift-logging`) — can match a different, concurrently-running test's LokiStack, causing spurious counts or "can't remove pod"/"not found" errors
- A resource read or extracted immediately after its owning object is created, when a controller populates the relevant field/key asynchronously — fails intermittently depending on controller timing, not the underlying feature
- Hardcoded version, image tag, channel, or namespace name that doesn't match the installed operator version
- A fixed-attempt HTTP retry loop against the gateway/query API (e.g. `doHTTPRequest()` in [test/e2e/utils.go](https://github.com/openshift-eng/openshift-logging-e2e-tests/blob/main/test/e2e/utils.go)) exhausting its attempts — if the same query succeeds on rerun with no operator-side error, it's a timing budget issue, not a product defect
- An assertion made right after `create`/`apply` with no poll before checking derived state — this repo's convention is a ~3s-interval, ~60s-timeout `wait.PollUntilContextTimeout`, not a single point-in-time check

### Cluster Instability indicators

Before classifying as `CLUSTER_INSTABILITY`, rule out a tight operator reconciliation loop:

```bash
oc logs -n openshift-operators-redhat deploy/loki-operator-controller-manager --tail=500 \
  | grep -E '"reconcileID"|"Reconciling"|"requeue"|"error"' \
  | head -100
```

**Indicators of ordinary resource contention (not a bug):** a StatefulSet/Deployment pod (e.g. `<lokistack-name>-index-gateway`, `-ruler`, `-distributor`) stuck `ContainerCreating` or `Pending` while `oc describe pod` shows normal image-pull-in-progress or scheduling events, with no `CrashLoopBackOff`; a bucket that has no data yet within the test's fixed wait window despite ingestion succeeding. These are consistent with a resource-constrained or freshly-provisioned cluster taking longer than the test's fixed wait window, not a defect.

Mandatory. Read `/tmp/qe-agent-modules/cluster-instability.md` (loop indicators and the four conditions for `CLUSTER_INSTABILITY`) and follow it. If missing: classify `CLUSTER_INSTABILITY` only when the MCPs were updating (or operator restarts correlate with the rollout) at the original run, all reruns pass cleanly and faster, and neither a test defect nor a reconciliation loop explains the failure; a loop is a `PRODUCT_BUG` (Step 5b); otherwise it takes precedence over `FLAKY` (Step 5d).

Diagnostics identifying `TEST_ISSUE` go to Step 5a; `PRODUCT_BUG` goes to Step 5b. Otherwise: `CLUSTER_INSTABILITY` (per `cluster-instability.md`) takes precedence over `FLAKY` — proceed to Step 5d. If all 4 Step 3 reruns passed, classify `NOT_REPRODUCED` and go to Step 6 (pass/fail pattern as evidence, Outcome = rerun recommendation, no code change). Otherwise classify `FLAKY` and proceed to Step 5c.

---

## Step 4a — Attribution

Mandatory. Read `/tmp/qe-agent-modules/attribution.md` and follow it, including its Step 5/6 additions. If missing, write `${ARTIFACT_DIR}/attribution.json` with `"status": "failed"` and continue.

## Step 5a — If TEST_ISSUE: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a test" and "Export the fix". Common fixes: add `"-n", <namespace>,` to a `processTemplate(oc, ...)` call; add `app.kubernetes.io/instance=<lokistack-name>` to an unscoped label selector; poll for `service-ca.crt` before extracting it; increase the `attempts` argument to `doHTTPRequest()` for a genuinely slow-but-correct query path. Files live under `/tmp/e2e-tests-src` (the repo root): export `test/e2e/<file>.go` preserving that relative path. If missing: make the minimal change, copy only the changed files to `${ARTIFACT_DIR}/test-fixes/` preserving the repo-relative path, and write `${ARTIFACT_DIR}/test-fixes/CHANGES.md` (banner `> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.`; Failing test, Root cause, Fix applied, Files changed, Verification).

---

## Step 5b — If PRODUCT_BUG: Write Bug Report

Mandatory. Read `/tmp/qe-agent-modules/product-bug-report.md` and follow it. Affected component: Loki Operator, namespace `openshift-operators-redhat`. If missing: write `${ARTIFACT_DIR}/bug-report.md` (AI-Generated Content banner as in Step 5a; Summary, Affected component, Reproduction, Observed behavior, Expected behavior, Evidence, Suggested severity) and `${ARTIFACT_DIR}/jira-payload.json` via `jq -n --arg`: `summary` (`[qe-agent]` prefix, ≤ 255 characters), `description` (the report in Jira wiki notation, starting with `*Severity:* <level>`) and `severity`. Redact credentials, tokens, passwords and SHA-256 digests as `[REDACTED]`.

---

## Step 5c — If FLAKY: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a flaky test" and "Export the fix". If missing: make the minimal change that removes the race (no blanket retries), export as in Step 5a, and put the pass/fail pattern from the 4 reruns in `CHANGES.md`. Typical fix: wrap the racing `Get`/`List` in a `wait.PollUntilContextTimeout` (3s interval, 60s timeout is the convention used elsewhere in this repo) instead of a single point-in-time check; increase `doHTTPRequest()`'s `attempts` argument for a slow-but-correct query path.

---

## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Mandatory. Follow "Incident note" in `/tmp/qe-agent-modules/analysis-summary.md`. If missing: write `${ARTIFACT_DIR}/cluster-instability-report.md` with the AI-Generated Content banner, a one-sentence summary, an affected-tests table (suite / test case / original vs rerun duration), the root cause (include the Step 0a MCP snapshot), evidence, and a recommendation to rerun the CI job.

---

## Step 6 — Write Analysis Summary

Mandatory. Follow "Analysis summary" in `/tmp/qe-agent-modules/analysis-summary.md`. Classifications also include `NOT_REPRODUCED` (Step 4). If missing: write `${ARTIFACT_DIR}/qe-agent-analysis.md` with the AI-Generated Content banner immediately after each diagnosis, without overwriting earlier tests' entries. Per test: Failed Tests, Rerun Result, Diagnosis (classification + evidence), Rerun Summary (Original + Reruns 1–4), Outcome, Evidence Sources. Finish with one Skill Improvement Recommendations section (deviations from skill steps, `None.` if none).

---

## Notes for CI context

- The cluster is already provisioned and cluster-logging-operator and loki-operator are already installed — do not reinstall
- The `openshift-logging-e2e-tests-tests-ext` binary is already on `PATH` — no build step is needed
- `$KUBECONFIG` is set and points to the test cluster; `oc`, `kubectl`, and `git` are available in PATH
- All output files must go to `$ARTIFACT_DIR` (uploaded to GCS by the sidecar) or `$SHARED_DIR` (accessible to other steps)
- **Namespace restriction**: You MUST NOT access, read, list, or modify any resources in the `kube-system` namespace. This namespace contains cloud provider credentials and platform-critical components. Do not run `oc get`, `oc describe`, `oc logs`, `kubectl`, or any other command that targets `kube-system`. If a diagnostic command defaults to all namespaces (e.g., `oc get pods -A`), filter out `kube-system` from the output before analysis
- This step runs `best_effort: true` — always exit 0 even if analysis is incomplete
