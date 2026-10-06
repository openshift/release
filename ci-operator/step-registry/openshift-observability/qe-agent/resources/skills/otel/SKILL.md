---
name: otel
description: Use this skill to analyze failing CI tests for the OpenShift OpenTelemetry Operator, rerun the specific failing tests (chainsaw-based, junit_otel_* prefix), diagnose whether the failure is a product bug or a test that needs fixing, apply fixes to test source files when needed, and export results to the artifact directory. Trigger whenever $SHARED_DIR/qe-agent-context.json is present with has_test_failures=true for OpenTelemetry Operator tests, or when an engineer asks to debug, rerun, or fix failing OTel QE tests.
---

# OpenTelemetry Operator QE Agent — Test Failure Triage and Fix

This skill drives an agentic loop that takes failing CI test results for the OpenTelemetry Operator, reruns the failing tests, determines root cause (product bug vs broken test), and either fixes the test or writes a structured bug report.

## Test Infrastructure Overview

| JUnit prefix | Suite | Framework | Repo |
|---|---|---|---|
| `junit_otel_*` | OpenTelemetry Operator | chainsaw | `https://github.com/openshift/open-telemetry-opentelemetry-operator` |

---

## Step 0 — Read Setup Context and Fetch the Step Script

Read `${SHARED_DIR}/qe-agent-context.json`. The test step writes it at exit time:

```json
{
  "step_script_ref": "distributed-tracing/tests/opentelemetry/downstream/distributed-tracing-tests-opentelemetry-downstream-commands.sh",
  "has_test_failures": true,
  "env": {
    "MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH": "rhosdt-3.9"
  }
}
```

- `step_script_ref` — path relative to `ci-operator/step-registry/` in the openshift/release repo
- `env` — runtime env var values that were injected at job time and are needed to reproduce setup (e.g. branch names, image refs); most steps have an empty `env`

Construct the raw GitHub URL and fetch the script:

```text
https://raw.githubusercontent.com/openshift/release/main/ci-operator/step-registry/<step_script_ref>
```

Read the script carefully. It is divided into two logical sections:
1. **Setup** — everything before the `chainsaw test` commands: cloning repos, `oc apply`, `kubectl create`, CSV patches, `make build`, env variable setup
2. **Test execution** — the `chainsaw test` invocations themselves

## Step 0a — Verify Cluster Stability

Mandatory, before Step 0b. Read `/tmp/qe-agent-modules/cluster-stability.md` and follow it. If missing: poll `oc get machineconfigpools.machineconfiguration.openshift.io` every 60s for up to 20 minutes until every pool is `UPDATED=True`, `UPDATING=False`, `DEGRADED=False`; if pools are listed but never become ready, classify `CLUSTER_INSTABILITY` (Step 5d) and skip to Step 6; if the query itself keeps failing, record the MCP status as unavailable, recommend a rerun and skip to Step 6.

## Step 0b — Re-establish the Test Environment

Export any env vars from the `env` field, then **run the setup section of the fetched script** — the commands up to (but not including) the first `chainsaw test` invocation.

Required adaptations:

| Script pattern | Adaptation |
|---|---|
| `cp -R /tmp/<name>` (image mount) | Replace with `git clone <repo> <dest>` — find the repo URL from `oc get csv -o yaml \| grep github.com` |
| `kubectl create -f <url>` (CRDs) | Use `kubectl apply -f <url>` — `create` fails if the CRD exists from the prior run |
| `oc patch csv ...` (initial setup patches) | Skip — the operator is already patched; verify with `oc get csv -n opentelemetry-operator-system` |
| `oc patch csv ...` (later patches: `LABELS_FILTER`, instrumentation images, etc.) | **Evaluate per-test**: later CSV patches create operator state that subsequent tests may not expect. When rerunning a single test out of the original execution order, check whether that test assumes a clean CSV or one with specific patches applied. If the test asserts on a CSV field that a prior patch modified (e.g., `LABELS_FILTER=.*filter.out`), either (a) reset the CSV field before the rerun, or (b) rerun the test in its original suite order. Document which CSV state the test requires in the diagnosis. |
| `$SKIP_TESTS` block | Skip entirely — `$SKIP_TESTS` is unset in the qe-agent pod |
| chainsaw test invocation | Run `unset NAMESPACE` before every `chainsaw test` call — a set `NAMESPACE` causes tests to run in the wrong namespace |

After setup, `cd` into the repo directory and proceed with Steps 1–6.

If `qe-agent-context.json` does not exist, infer the suite from the JUnit file name prefix (`junit_otel_*` → OpenTelemetry) and skip the rerun — proceed directly to diagnosis from the JUnit content and cluster state.

## Step 1 — Parse JUnit XMLs and Identify Failures

Mandatory. Read `/tmp/qe-agent-modules/junit-triage.md` and follow it. Typical shared root causes here: operator crash, missing CRD, install failure. Representative test: the one with the fewest steps in `chainsaw-test.yaml`. If missing: read `${SHARED_DIR}/qe-agent-junit-*.xml`, extract each suite name and failed `<testcase>` (`<failure>`/`<error>` message and full text), group by suite, and exit with a clear message if there are no files. If more than 5 tests fail, look for one shared root cause and diagnose the simplest failing test as the representative (Steps 2–5); with no pattern, diagnose individually, capped at 3. Write any pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.

---

## Step 2 — Locate Test Source Files

The JUnit test case name usually matches the folder name under the test directory. For example, a failing test named `e2e/targetallocator` corresponds to `tests/e2e/targetallocator/`. Inside that folder look for:
- `chainsaw-test.yaml` — the test definition (steps, assertions)
- `*.yaml` resource manifests applied during the test
- `assert.yaml` / `error.yaml` — explicit assertion files

To find the right folder when the name mapping is unclear, use:
```bash
find <repo-root>/tests -type d -path "*/<test-name>"
```

Use `-path` (not `-name`) — `-path` matches the full directory path so nested folders like `e2e/targetallocator` are found; `-name` only matches the final component and will miss them.

Once located, record this as `TEST_DIR` (e.g. `tests/e2e/targetallocator`). The rerun commands in Step 3 reference `${TEST_DIR}` directly.

---

## Step 3 — Rerun the Failing Tests

Rerun only the specific failing tests, not the entire suite, to save time and keep the rerun focused.

### Cleaning up test resources before each rerun

Chainsaw reruns use `--skip-delete` so resources persist — clean up before each rerun or the next run collides with leftover state. `kubectl delete -f <test-folder>/` is insufficient because chainsaw also creates resources via script steps, operator reconciliation, and cluster-scoped objects.

Chainsaw generates random namespace names (e.g., `chainsaw-advanced-griffon`) rather than using predictable `chainsaw-<test-name>` names. Use a namespace discovery approach instead of assuming a known name:

```bash
# Find and delete all chainsaw-created namespaces for this test
for ns in $(kubectl get namespaces --no-headers -o custom-columns=':metadata.name' | grep '^chainsaw-'); do
  kubectl delete namespace "$ns" --ignore-not-found=true
done
# Wait for all chainsaw namespaces to be fully deleted
for ns in $(kubectl get namespaces --no-headers -o custom-columns=':metadata.name' | grep '^chainsaw-'); do
  kubectl wait --for=delete namespace/"$ns" --timeout=5m 2>/dev/null || true
done
kubectl delete clusterrole,clusterrolebinding \
  -l app.kubernetes.io/managed-by=chainsaw \
  --ignore-not-found=true
```

Read `chainsaw-test.yaml` before cleanup to identify any additional cluster-scoped resources the test creates via script steps.

### OpenTelemetry Operator — first rerun

```bash
# Declare TEST_DIR explicitly — each bash invocation starts a fresh shell.
TEST_DIR="<value resolved in Step 2>"

# Read the fetched step script to check whether --selector is used.
# Example: grep -o '\-\-selector [^ ]*' /tmp/fetched-step-script.sh | awk '{print "--selector", $2}'
OTEL_SELECTOR=""  # set to "--selector <value>" if the original script uses one, otherwise leave empty

unset NAMESPACE
CHAINSAW_CMD="chainsaw test --skip-delete --quiet --report-name junit_rerun_otel --report-path ${ARTIFACT_DIR} --report-format XML"
CHAINSAW_CMD+=" --test-dir ${TEST_DIR}"
[[ -n "${OTEL_SELECTOR}" ]] && CHAINSAW_CMD+=" ${OTEL_SELECTOR}"
eval "$CHAINSAW_CMD"
```

After the rerun, read the fresh JUnit XML. If still failing → proceed to Step 4. If it passed → possible flakiness; run 3 more times (see flakiness loop below).

### Flakiness confirmation loop

If the test passes on the first rerun, run it 3 more times sequentially. Clean up test resources before each run (same namespace + clusterrole delete pattern as above). Use a unique `--report-name` per run so the XMLs don't overwrite each other:

```bash
# Each bash invocation starts a fresh shell — re-declare variables from the first rerun.
TEST_DIR="<value resolved in Step 2>"
OTEL_SELECTOR="<value captured during first rerun>"  # empty string if no --selector was used

for i in 2 3 4; do
  for ns in $(kubectl get namespaces --no-headers -o custom-columns=':metadata.name' | grep '^chainsaw-'); do
    kubectl delete namespace "$ns" --ignore-not-found=true
  done
  for ns in $(kubectl get namespaces --no-headers -o custom-columns=':metadata.name' | grep '^chainsaw-'); do
    kubectl wait --for=delete namespace/"$ns" --timeout=5m 2>/dev/null || true
  done
  kubectl delete clusterrole,clusterrolebinding \
    -l app.kubernetes.io/managed-by=chainsaw \
    --ignore-not-found=true

  unset NAMESPACE
  CHAINSAW_CMD="chainsaw test --skip-delete --quiet --report-name junit_rerun_otel_run${i} --report-path ${ARTIFACT_DIR} --report-format XML"
  CHAINSAW_CMD+=" --test-dir ${TEST_DIR}"
  [[ -n "${OTEL_SELECTOR}" ]] && CHAINSAW_CMD+=" ${OTEL_SELECTOR}"
  eval "$CHAINSAW_CMD"
done
```

After all 4 runs, count how many passed vs failed. Record the pass/fail pattern (e.g., `PFPP`, `PPFP`). Then inspect the test source:
- Look for missing `wait` blocks between an action and an assertion
- Look for very short `timeout` values in chainsaw steps (e.g., `timeout: 30s` where the operator may take longer)
- Look for assertions that depend on ordering of concurrent resources

If the failure is reproducible even 1 out of 4 runs, classify as `FLAKY` and proceed to Step 5c to fix it.

---

## Step 4 — Diagnose: Product Bug vs Test Issue

Read the failure message, rerun output, and test source files together. Then run the full operator diagnostics below before making any classification decision — the logs and resource status are the primary evidence.

### OpenTelemetry Operator Diagnostics

```bash
# Operator pod status and logs
oc get pods -n opentelemetry-operator-system
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --tail=150
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --previous --tail=50 2>/dev/null || true

# OpenTelemetryCollector instances across all namespaces
oc get opentelemetrycollectors --all-namespaces -o wide
oc get opentelemetrycollectors --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.conditions[*].type}={.status.conditions[*].status} {.status.conditions[*].message}{"\n"}{end}'

# Instrumentation, OpAMPBridge CRs
oc get instrumentations --all-namespaces -o wide 2>/dev/null || true
oc get opampbridges --all-namespaces -o wide 2>/dev/null || true

# Collector and sidecar pods in the test namespace
oc get pods -n <test-namespace> -o wide
oc describe pods -n <test-namespace> | grep -A10 -E 'Events:|Reason:|State:|Exit Code:'

# Events in operator namespace and test namespace
oc get events -n opentelemetry-operator-system --sort-by='.lastTimestamp' | tail -20
oc get events -n <test-namespace> --sort-by='.lastTimestamp' | tail -30

# SCC-related pod creation failures (DaemonSet hostNetwork/privileged tests)
oc get events -n <test-namespace> --field-selector reason=FailedCreate --sort-by='.lastTimestamp'

# CSV and subscription status
oc get csv -n opentelemetry-operator-system -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase} — {.status.message}{"\n"}{end}'
oc get subscription -n opentelemetry-operator-system -o jsonpath='{range .items[*]}{.metadata.name}: {.status.currentCSV} state={.status.state}{"\n"}{end}' 2>/dev/null || true
```

### CRD and API availability check

```bash
# Missing CRDs cause many test failures
oc get crd | grep -E 'opentelemetry|observability'
oc api-resources | grep opentelemetry
```


### Product Bug indicators
Classify as `PRODUCT_BUG` when the evidence shows the operator or operand itself misbehaved:
- Operator pod in `CrashLoopBackOff` or `OOMKilled`
- `OpenTelemetryCollector` stuck in an error state not caused by the test YAML
- API object that the operator should have created is missing
- Image pull failure for an operand image referenced in the CSV
- CRD validation error rejecting a valid CR that worked in a prior release
- Timeout waiting for operator reconciliation when the operator logs show no activity

### Test Issue indicators
Classify as `TEST_ISSUE` when the test itself is wrong or stale:
- Hardcoded version string or image tag in the test YAML that doesn't match the currently installed operator version
- Wrong namespace name in an assertion (namespace changed between releases)
- Race condition: the test asserts a resource state before the operator has had time to act — look for very short `timeout` values in chainsaw steps or missing `wait` blocks
- Missing prerequisite in the test setup (CRD that must be installed before the test runs but isn't part of the test's `setup` steps)
- Assertion checks a field or value that changed in the operator API (e.g., a renamed status condition)
- Missing SCC setup for DaemonSet tests that use `hostNetwork: true` or privileged containers — compare with working DaemonSet tests (e.g., `smoke-collector-daemonset`) that include an SCC binding step

### Cluster Instability indicators

Before classifying as `CLUSTER_INSTABILITY`, rule out a tight operator reconciliation loop (which causes identical-looking API server pressure). Enable debug logging first:

```bash
CSV=$(oc get csv -n opentelemetry-operator-system --no-headers \
  | awk '/opentelemetry-operator/ && /Succeeded/{print $1}' | head -1)
IDX=$(oc get csv "$CSV" -n opentelemetry-operator-system \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}' \
  | awk '/--zap-log-level/{print NR-1; exit}')
if [[ -z "$IDX" ]]; then echo "ERROR: --zap-log-level not found in CSV args"; exit 1; fi
oc patch csv "$CSV" -n opentelemetry-operator-system --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args/${IDX}\",\"value\":\"--zap-log-level=debug\"}]"
oc rollout status deploy/opentelemetry-operator-controller-manager -n opentelemetry-operator-system --timeout=3m
# Let the operator run 2–3 minutes, then check for reconciliation loops:
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --tail=500 \
  | grep -E '"reconcileID"|"Reconciling"|"requeue"|"error"' | head -100
```

Mandatory. Read `/tmp/qe-agent-modules/cluster-instability.md` (loop indicators and the four conditions for `CLUSTER_INSTABILITY`) and follow it. If missing: classify `CLUSTER_INSTABILITY` only when the MCPs were updating (or operator restarts correlate with the rollout) at the original run, all reruns pass cleanly and faster, and neither a test defect nor a reconciliation loop explains the failure; a loop is a `PRODUCT_BUG` (Step 5b); otherwise it takes precedence over `FLAKY` (Step 5d).

---

## Step 4a — Attribution

Mandatory. Read `/tmp/qe-agent-modules/attribution.md` and follow it, including its Step 5/6 additions. If missing, write `${ARTIFACT_DIR}/attribution.json` with `"status": "failed"` and continue.

## Step 5a — If TEST_ISSUE: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a test" and "Export the fix". Edit `chainsaw-test.yaml`, `assert.yaml`, resource manifests, or other YAML files in the test folder. Common fixes: update image/version references, fix namespace, add a `wait` step before an assertion, correct a changed field name in assertions. If missing: make the minimal change, copy only the changed files to `${ARTIFACT_DIR}/test-fixes/` preserving the repo-relative path, and write `${ARTIFACT_DIR}/test-fixes/CHANGES.md` (banner `> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.`; Failing test, Root cause, Fix applied, Files changed, Verification).

---

## Step 5b — If PRODUCT_BUG: Write Bug Report

Mandatory. Read `/tmp/qe-agent-modules/product-bug-report.md` and follow it. Affected component: OpenTelemetry Operator, namespace `opentelemetry-operator-system`. If missing: write `${ARTIFACT_DIR}/bug-report.md` (AI-Generated Content banner as in Step 5a; Summary, Affected component, Reproduction, Observed behavior, Expected behavior, Evidence, Suggested severity) and `${ARTIFACT_DIR}/jira-payload.json` via `jq -n --arg`: `summary` (`[qe-agent]` prefix, ≤ 255 characters), `description` (the report in Jira wiki notation, starting with `*Severity:* <level>`) and `severity`. Redact credentials, tokens, passwords and SHA-256 digests as `[REDACTED]`.

---

## Step 5c — If FLAKY: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a flaky test" and "Export the fix". If missing: make the minimal change that removes the race (no blanket retries), export as in Step 5a, and put the pass/fail pattern from the 4 reruns in `CHANGES.md`.

If a step asserts state immediately after a resource is applied, add an explicit `wait` step before the assertion. Example:

```yaml
- name: Wait for collector to be ready before asserting
  wait:
    apiVersion: opentelemetry.io/v1alpha1
    kind: OpenTelemetryCollector
    name: otel-collector
    timeout: 2m
    for:
      condition:
        name: Ready
        value: "True"
```

Other common fixes: increase a `timeout: 30s` → `2m` to give the operator time to reconcile; reorder steps so a dependency is created before the resource that needs it.

---

## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Mandatory. Follow "Incident note" in `/tmp/qe-agent-modules/analysis-summary.md`. If missing: write `${ARTIFACT_DIR}/cluster-instability-report.md` with the AI-Generated Content banner, a one-sentence summary, an affected-tests table (suite / test case / original vs rerun duration), the root cause (include the Step 0a MCP snapshot), evidence, and a recommendation to rerun the CI job.

---

## Step 6 — Write Analysis Summary

Mandatory. Follow "Analysis summary" in `/tmp/qe-agent-modules/analysis-summary.md`. If missing: write `${ARTIFACT_DIR}/qe-agent-analysis.md` with the AI-Generated Content banner immediately after each diagnosis, without overwriting earlier tests' entries. Per test: Failed Tests, Rerun Result, Diagnosis (classification + evidence), Rerun Summary (Original + Reruns 1–4), Outcome, Evidence Sources. Finish with one Skill Improvement Recommendations section (deviations from skill steps, `None.` if none).

---

## Notes for CI context

- The cluster is already provisioned and the OpenTelemetry operator is already installed — do not reinstall the operator
- The test repo is set up by Step 0b using commands from the fetched step script — the repo path is the destination shown in the script (e.g., `/tmp/opentelemetry-tests`). The qe-agent runs in a fresh pod so `/tmp/` is always empty at start; Step 0b populates it
- `$KUBECONFIG` is set and points to the test cluster; `oc`, `kubectl`, and `chainsaw` are available in PATH
- All output files must go to `$ARTIFACT_DIR` (uploaded to GCS by the sidecar) or `$SHARED_DIR` (accessible to other steps)
- **Namespace restriction**: You MUST NOT access, read, list, or modify any resources in the `kube-system` namespace. This namespace contains cloud provider credentials and platform-critical components. Do not run `oc get`, `oc describe`, `oc logs`, `kubectl`, or any other command that targets `kube-system`. If a diagnostic command defaults to all namespaces (e.g., `oc get pods -A`), filter out `kube-system` from the output before analysis
- This step runs `best_effort: true` — always exit 0 even if analysis is incomplete
