---
name: otel-qe-agent
description: Use this skill to analyze failing CI tests for the OpenShift OpenTelemetry Operator, rerun the specific failing tests (chainsaw-based, junit_otel_* prefix), diagnose whether the failure is a product bug or a test that needs fixing, apply fixes to test source files when needed, and export results to the artifact directory. Trigger whenever $SHARED_DIR/qe-agent-context.json is present with has_test_failures=true for OpenTelemetry Operator tests, or when an engineer asks to debug, rerun, or fix failing OTel QE tests.
---

# OpenTelemetry Operator QE Agent — Test Failure Triage and Fix

This skill drives an agentic loop that takes failing CI test results for the OpenTelemetry Operator, reruns the failing tests, determines root cause (product bug vs broken test), and either fixes the test or writes a structured bug report.

## Test Infrastructure Overview

| JUnit prefix | Suite | Framework | Repo |
|---|---|---|---|
| `junit_otel_*` | OpenTelemetry Operator | chainsaw | `https://github.com/openshift/opentelemetry-operator` |

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

Before running any prerequisites setup or test reruns, confirm the cluster is stable. The original CI test step may have applied resources that triggered MachineConfig updates — running tests while nodes are updating causes spurious failures.

```bash
oc get machineconfigpools.machineconfiguration.openshift.io
```

Each MachineConfigPool must have `UPDATED=True`, `UPDATING=False`, `DEGRADED=False`, and `READYMACHINECOUNT=MACHINECOUNT` before proceeding. Wait in a 60s poll loop with a 20-minute hard timeout; if the deadline fires, print MCP status and abort:

```bash
# Wait until all MCPs are updated, not updating, and not degraded (20-minute timeout)
deadline=$((SECONDS + 1200))
while oc get machineconfigpools.machineconfiguration.openshift.io \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Updated")].status}{" "}{.status.conditions[?(@.type=="Updating")].status}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' \
    | grep -qvE '^True False False$'; do
  echo "MCPs not ready yet, waiting 60s..."
  if (( SECONDS >= deadline )); then
    echo "ERROR: MCPs still not ready after 20 minutes — cluster is unhealthy."
    oc get machineconfigpools.machineconfiguration.openshift.io
    exit 1
  fi
  sleep 60
  oc get machineconfigpools.machineconfiguration.openshift.io
done
echo "All MCPs ready — proceeding."
```

## Step 0b — Re-establish the Test Environment

Export any env vars from the `env` field, then **run the setup section of the fetched script** — the commands up to (but not including) the first `chainsaw test` invocation.

Required adaptations:

| Script pattern | Adaptation |
|---|---|
| `cp -R /tmp/<name>` (image mount) | Replace with `git clone <repo> <dest>` — find the repo URL from `oc get csv -o yaml \| grep github.com` |
| `kubectl create -f <url>` (CRDs) | Use `kubectl apply -f <url>` — `create` fails if the CRD exists from the prior run |
| `oc patch csv ...` | Skip — the operator is already patched; verify with `oc get csv -n opentelemetry-operator-system` |
| `$SKIP_TESTS` block | Skip entirely — `$SKIP_TESTS` is unset in the qe-agent pod |
| chainsaw test invocation | Run `unset NAMESPACE` before every `chainsaw test` call — a set `NAMESPACE` causes tests to run in the wrong namespace |

After setup, `cd` into the repo directory and proceed with Steps 1–6.

If `qe-agent-context.json` does not exist, infer the suite from the JUnit file name prefix (`junit_otel_*` → OpenTelemetry) and skip the rerun — proceed directly to diagnosis from the JUnit content and cluster state.

## Step 1 — Parse JUnit XMLs and Identify Failures

Read all JUnit XML files from `${SHARED_DIR}/qe-agent-junit-*.xml` (flat files copied by the test step trap function).

For each XML file, extract:
- **Suite name** (`name` attribute on `<testsuite>`)
- **Failed test cases**: `<testcase>` elements that contain a `<failure>` or `<error>` child
- **Failure message**: the `message` attribute and text body of `<failure>`/`<error>`
- **Stack trace / details**: the full text content of the failure element

Group failures by suite so you process each operator's failures together.

If no `${SHARED_DIR}/qe-agent-junit-*.xml` files are found, exit with a clear message — the test steps did not run or produced no results.

### High-failure triage: more than 5 failures total

When more than 5 tests fail, look for a common pattern (same error string, same failing chainsaw step, same namespace/resource, or failure times clustered tightly within seconds of each other) — this usually means one root cause (operator crash, missing CRD, install failure).

- **Pattern found**: pick the simplest failing test (fewest steps in `chainsaw-test.yaml`) as the representative case; proceed with Steps 2–5 for that test only.
- **No pattern**: process failures individually, cap at 3 tests, and note this in the summary.

Write the pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.

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

```bash
kubectl delete namespace chainsaw-<test-name> --ignore-not-found=true
kubectl wait --for=delete namespace/chainsaw-<test-name> --timeout=5m 2>/dev/null || true
kubectl delete clusterrole,clusterrolebinding \
  -l app.kubernetes.io/managed-by=chainsaw \
  -l chainsaw.kyverno.io/test-namespace=chainsaw-<test-name> \
  --ignore-not-found=true
# Fallback label if the above selector matches nothing:
# -l chainsaw.kyverno.io/test-name=<test-name>
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
  kubectl delete namespace chainsaw-<test-name> --ignore-not-found=true
  kubectl wait --for=delete namespace/chainsaw-<test-name> --timeout=5m 2>/dev/null || true
  kubectl delete clusterrole,clusterrolebinding \
    -l app.kubernetes.io/managed-by=chainsaw \
    -l chainsaw.kyverno.io/test-namespace=chainsaw-<test-name> \
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

A reconciliation loop (same CR reconciled >1/2s, growing queue depth, rapid sub-second `requeue` entries) reclassifies to `PRODUCT_BUG`. If reconciles are spaced 10+ seconds apart with stable log volume, classify as `CLUSTER_INSTABILITY` only when **all four** conditions hold: (1) MCPs were updating or the operator showed probe-failure restarts correlated with MCP rollout at the original run time; (2) tests pass cleanly on all 4 reruns; (3) no fixable test defect — if any timeout, version pin, or assertion would fail under foreseeable cluster load (including normal scheduling pressure during node updates), that is a `TEST_ISSUE` to fix, not infrastructure instability; (4) no tight reconciliation loop confirmed above. `CLUSTER_INSTABILITY` takes precedence over `FLAKY` when all four hold. Proceed to Step 5d.

When genuinely ambiguous, gather more cluster evidence before deciding. Explain your reasoning explicitly in the output.

---

## Step 5a — If TEST_ISSUE: Fix and Export

Apply the **minimal** change to make the test correct. Avoid refactoring or improving unrelated parts of the test — a focused, small diff is easier to review and merge.

Edit `chainsaw-test.yaml`, `assert.yaml`, resource manifests, or other YAML files in the test folder. Common fixes: update image/version references, fix namespace, add a `wait` step before an assertion, correct a changed field name in assertions.

After editing, copy only the changed files to `${ARTIFACT_DIR}/test-fixes/` **preserving the directory path relative to the repo root**:

```bash
# Example: tests/e2e/targetallocator/chainsaw-test.yaml was fixed
dest="${ARTIFACT_DIR}/test-fixes/tests/e2e/targetallocator"
mkdir -p "${dest}"
cp tests/e2e/targetallocator/chainsaw-test.yaml "${dest}/"
```

Write a `${ARTIFACT_DIR}/test-fixes/CHANGES.md` using this structure:

```markdown
# Test Fix Summary

## Failing test
<suite name> / <test case name>

## Root cause
<one paragraph explaining what was wrong in the test and why>

## Fix applied
<what was changed, which files, what specifically>

## Files changed
- `tests/e2e/<folder>/chainsaw-test.yaml`

## Verification
Rerun result after fix: [PASS / FAIL / not re-verified]
```

---

## Step 5b — If PRODUCT_BUG: Write Bug Report

Do not attempt to fix the operator code. Instead, write `${ARTIFACT_DIR}/bug-report.md`:

````markdown
# Product Bug Report

## Summary
<one-sentence description of the bug>

## Affected component
- Operator: OpenTelemetry Operator
- Namespace: opentelemetry-operator-system
- Failing test: <suite / test case>

## Reproduction
1. <Step-by-step reproduction based on what the test does>

## Observed behavior
<What happened — include the exact failure message from JUnit>

## Expected behavior
<What should have happened>

## Evidence
### Operator logs
```text
<relevant log lines>
```

### Cluster events
```text
<relevant events>
```

### JUnit failure message
```text
<failure text from XML>
```

## Suggested severity
<Critical / Major / Minor — based on whether this blocks a release gate>
````

---

## Step 5c — If FLAKY: Fix and Export

Apply the minimal change that eliminates the race or timing condition. Do not suppress flakiness with blanket retries — find and fix the root cause.

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

After editing, copy changed files to `${ARTIFACT_DIR}/test-fixes/` (same structure as Step 5a). Write `CHANGES.md` with the pass/fail pattern from the 4 reruns as evidence.

---

## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Write `${ARTIFACT_DIR}/cluster-instability-report.md` with: a one-sentence summary; a table of affected tests (suite / test case / original duration / rerun duration); root cause (MCP updates, node evictions, operator pod restarts/leader election loss — include the MCP status snapshot from Step 0a); evidence (MCP output, relevant pod events); and a recommendation to rerun the CI job.

---

## Step 6 — Write Analysis Summary

Write `${ARTIFACT_DIR}/qe-agent-analysis.md` immediately after each test is diagnosed — do not wait until the end. Overwrite it after each subsequent test. Write partial entries for in-progress flakiness runs ("Rerun 1: PASS — confirmation in progress") and overwrite when complete. Record any deviations from the skill steps in the **Skill Improvement Recommendations** section.

````markdown
# QE Agent Analysis

## Failed Tests
| Suite | Test Case | JUnit File |
|---|---|---|
| <suite> | <test-case> | <xml-filename> |

## Rerun Result
<still failing / passed on rerun (flaky) / passed cleanly (cluster instability) / not rerun>

## Diagnosis
**<PRODUCT_BUG | TEST_ISSUE | FLAKY | CLUSTER_INSTABILITY>**

<Two to three sentences explaining the reasoning. Reference specific log lines, error messages, MCP status, or test YAML fields that led to this conclusion.>

## Rerun Summary
| Run | Result |
|---|---|
| Original CI run | FAIL |
| Rerun 1 | PASS / FAIL |
| Rerun 2 | PASS / FAIL |
| Rerun 3 | PASS / FAIL |
| Rerun 4 | PASS / FAIL |

## Outcome
<If TEST_ISSUE>: Test fix applied. Changed files in `${ARTIFACT_DIR}/test-fixes/`. See `CHANGES.md` for details.
<If PRODUCT_BUG>: Bug report written to `${ARTIFACT_DIR}/bug-report.md`.
<If FLAKY>: Flaky test confirmed (pattern: <e.g. PFPP>). Fix applied to `${ARTIFACT_DIR}/test-fixes/`. See `CHANGES.md` for root cause and fix details.
<If CLUSTER_INSTABILITY>: Incident note written to `${ARTIFACT_DIR}/cluster-instability-report.md`. Recommendation: rerun the CI job.

## Skill Improvement Recommendations
<!-- Record any deviation from the skill steps here — wrong commands, missing steps, steps that needed adaptation, or better approaches discovered during this run.
Examples of what belongs here:
- A command in the skill failed and had to be adapted (wrong flag, missing argument, changed API)
- A diagnostic the skill did not mention turned out to be the decisive evidence
- A step the skill prescribed was unnecessary or wasted significant time
- The cleanup approach did not work and a different method had to be used
- An assumption in the skill (namespace, resource name, container index) did not hold for this operator version
-->
<If the skill steps were followed exactly and worked as written>: None.
<Otherwise, one bullet per finding>:
- **Step <N> — <short title>**: <What the skill said to do> → <What actually worked / what was wrong and why>. Suggested fix: <concrete change to the skill>.
````

---

## Notes for CI context

- The cluster is already provisioned and the OpenTelemetry operator is already installed — do not reinstall the operator
- The test repo is set up by Step 0b using commands from the fetched step script — the repo path is the destination shown in the script (e.g., `/tmp/opentelemetry-tests`). The qe-agent runs in a fresh pod so `/tmp/` is always empty at start; Step 0b populates it
- `$KUBECONFIG` is set and points to the test cluster; `oc`, `kubectl`, and `chainsaw` are available in PATH
- All output files must go to `$ARTIFACT_DIR` (uploaded to GCS by the sidecar) or `$SHARED_DIR` (accessible to other steps)
- This step runs `best_effort: true` — always exit 0 even if analysis is incomplete
