---
name: qe-agent
description: Use this skill to analyze failing CI tests for Red Hat OpenShift Distributed Tracing (OpenTelemetry Operator, Tempo Operator, Tracing UI console plugin), rerun the specific failing tests, diagnose whether the failure is a product bug or a test that needs fixing, apply fixes to test source files when needed, and export results to the artifact directory. Trigger whenever $SHARED_DIR/qe-agent-context.json is present with has_test_failures=true or when an engineer asks to debug, rerun, or fix failing distributed tracing QE tests.
---

# RHOSDT QE Agent — Test Failure Triage and Fix

This skill drives an agentic loop that takes failing CI test results, reruns the failing tests, determines root cause (product bug vs broken test), and either fixes the test or writes a structured bug report.

## Test Infrastructure Overview

Three test suites are supported. The JUnit report name prefix tells you which suite failed:

| JUnit prefix | Suite | Framework | Repo |
|---|---|---|---|
| `junit_otel_*` | OpenTelemetry Operator | chainsaw | `https://github.com/openshift/opentelemetry-operator` |
| `junit_tempo_*` | Tempo Operator | chainsaw | `https://github.com/grafana/tempo-operator` |
| `junit_distributed-tracing-console-plugin*` | Tracing UI (Cypress) | Cypress/npm | `https://github.com/openshift/distributed-tracing-console-plugin` |
| `junit_distributed_tracing_disconnected` | Disconnected (distributed-tracing-qe) | chainsaw | `https://github.com/openshift/distributed-tracing-qe` |

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
1. **Setup** — everything before the `chainsaw test` or `npx cypress run` commands: cloning repos, `oc apply`, `kubectl create`, CSV patches, `make build`, env variable setup
2. **Test execution** — the `chainsaw test` / `npx cypress run` invocations themselves

## Step 0a — Verify Cluster Stability

Before running any prerequisites setup or test reruns, confirm the cluster is stable. The original CI test step may have applied resources that triggered MachineConfig updates — running tests while nodes are updating causes spurious failures.

```bash
oc get machineconfigpools.machineconfiguration.openshift.io
```

For each MachineConfigPool, all of the following must be true before proceeding:
- `UPDATED` = `True`
- `UPDATING` = `False`
- `DEGRADED` = `False`
- `READYMACHINECOUNT` = `MACHINECOUNT` (all machines ready)

**If any pool is not ready**, wait and recheck every 60 seconds:

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

If the timeout fires, the loop prints the current MCP status and exits — the cluster is unhealthy and test results would be unreliable.

## Step 0b — Re-establish the Test Environment

Export any env vars from the `env` field, then **run the setup section of the fetched script** — the commands up to (but not including) the first `chainsaw test` or `npx cypress run` invocation.

Key adaptations when running setup commands from the script:

- **Image-mount `cp -R` → `git clone`**: Several step scripts copy test repos from image mounts that don't exist in the qe-agent pod. Replace each with a `git clone`:
  - `cp -R /tmp/opentelemetry-operator /tmp/opentelemetry-tests` → `git clone https://github.com/openshift/opentelemetry-operator.git /tmp/opentelemetry-tests`
  - `cp -R /tmp/distributed-tracing-qe /tmp/distributed-tracing-tests` → `git clone https://github.com/openshift/distributed-tracing-qe.git /tmp/distributed-tracing-tests`
  - For any other `cp -R /tmp/<name>` pattern, check `oc get csv -o yaml | grep github.com` or the CSV annotations to identify the source repo and clone from there.

- **`kubectl create -f <url>` for CRDs** — change to `kubectl apply -f <url>` since `create` fails if the CRD already exists from the original test run; `apply` is idempotent.

- **CSV patches (`oc patch csv ...`)** — the operator is already installed and already patched from the original test step. Skip these unless the test you are rerunning specifically requires a freshly patched CSV. Check `oc get csv -n <namespace>` to verify env vars are already set.

- **`unset NAMESPACE`** — always run this before chainsaw to avoid conflicts.

- **`SKIP_TESTS` processing** — the setup sections of several scripts contain a block that reads `$SKIP_TESTS` and removes test directories. Skip this block entirely: `$SKIP_TESTS` is not set in the qe-agent pod, and for reruns you want all test directories present so you can target the specific failing one.

- **GOPATH / `make build` (Tempo stage and downstream only)** — the Tempo stage and downstream scripts export `GOPATH=/tmp/go`, `GOBIN=/tmp/go/bin`, `GOCACHE=/tmp/.cache/go-build` and run `make build` to compile test helpers. Run these as part of setup. Because each bash invocation starts a fresh shell, you must re-export `GOPATH`, `GOBIN`, `GOCACHE`, and `PATH` (with `GOBIN` prepended) at the start of any bash call in Steps 3–6 that runs chainsaw for Tempo stage or downstream tests — without `PATH` updated, helper binaries compiled into `/tmp/go/bin` cannot be found by name.

- **IDP / htpasswd setup (Tracing UI only)** — the Tracing UI setup creates an htpasswd secret and patches the cluster oauth. Check if the secret already exists (`oc get secret htpass-secret -n openshift-config`) before running `oc create secret` — skip creation if it does. Similarly, only patch oauth if the htpasswd IDP is not already configured.

After setup, `cd` into the repo directory and proceed with Steps 1–6.

If `qe-agent-context.json` does not exist, infer the suite from the JUnit file name prefix (`junit_otel_*` → OpenTelemetry, `junit_tempo_*` → Tempo, `junit_distributed-tracing-console-plugin*` → Tracing UI, `junit_distributed_tracing_disconnected` → Disconnected) and skip the rerun — proceed directly to diagnosis from the JUnit content and cluster state.

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

When the total number of failing test cases across all suites is more than 5, it is very likely that all failures share a single root cause (operator crash, missing CRD, network partition, install failure) rather than being independent bugs. Debugging all of them individually wastes time and produces redundant output.

**What to do:**

1. **Look for a common pattern** across the failure messages. Common indicators:
   - All messages contain the same error string (e.g., `connection refused`, `resource not ready`, `no such host`, `image pull failed`, `CRD not found`)
   - All tests fail at the same chainsaw step name (e.g., `step-01-apply`, `assert`)
   - All failures reference the same namespace, resource kind, or operator condition
   - Failure times are clustered tightly (within seconds of each other) — indicating the cluster state changed once and all tests hit it

2. **If a clear pattern exists**: pick the **simplest failing test** (fewest steps in `chainsaw-test.yaml`, or shortest failure message) as the representative case. Record the pattern and the chosen representative in the analysis summary. Proceed with Steps 2–5 for that one test only, skipping the rest.

3. **If no clear pattern**: the failures are likely independent. Fall back to processing each failure individually (standard flow) but cap at 3 tests to stay within time budget — note in the summary that only the first 3 were investigated.

Write the pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md` so it is visible immediately.

---

## Step 2 — Locate Test Source Files

For **chainsaw** suites (OpenTelemetry, Tempo):

The JUnit test case name usually matches the folder name under the test directory. For example, a failing test named `e2e/targetallocator` corresponds to `tests/e2e/targetallocator/`. Inside that folder look for:
- `chainsaw-test.yaml` — the test definition (steps, assertions)
- `*.yaml` resource manifests applied during the test
- `assert.yaml` / `error.yaml` — explicit assertion files

To find the right folder when the name mapping is unclear, use `find <repo-root>/tests -type d -path "*/<test-name>"`.
The `-path` flag matches the full directory path, so nested test folders like `e2e/targetallocator` are found correctly; `-name` only matches the final path component and will miss them.

Once located, record this as `TEST_DIR` (e.g. `tests/e2e/targetallocator`). The rerun commands in Step 3 reference `${TEST_DIR}` directly.

For **Cypress** suites (Tracing UI):

The failing test name maps to a `describe` + `it` block inside `.cy.js` or `.cy.ts` files under `tests/cypress/e2e/`. Use `grep -r "<test-name>"` to locate the spec file.

The repo location and how it was set up is determined by the fetched step script (Step 0b). By the time you reach Step 2, the setup commands from that script have already been run:
- **Upstream tests**: the step script does `cp -R /tmp/<operator> /tmp/<tests>` — since the source is an image mount that does not exist in the qe-agent pod, Step 0b substitutes this with a `git clone`. The repo is at the destination path shown in the script (e.g., `/tmp/opentelemetry-tests`, `/tmp/tempo-tests`).
- **Downstream / stage tests**: the step script does `git clone <url> /tmp/<tests>` directly. Step 0b runs this clone. The repo is at the path shown in the script.

Use the destination path from the step script as your repo root — do not guess or check `/tmp/` broadly.

---

## Step 3 — Rerun the Failing Tests

Rerun only the specific failing tests, not the entire suite, to save time and keep the rerun focused.

### Cleaning up test resources before each rerun

Chainsaw reruns use `--skip-delete` so resources remain on the cluster after the test finishes — this lets you inspect them and understand why a test failed. However, because resources persist, **you must clean up before running the same test again**, otherwise the next run will collide with leftover state.

`kubectl delete -f <test-folder>/` is **not sufficient** — chainsaw tests create resources in multiple ways beyond static YAML files:
- Script steps that run `kubectl apply` / `oc apply` dynamically
- Resources created by the operator itself in response to CRs (e.g., a `TempoStack` CR triggers the operator to create Deployments, Services, ConfigMaps)
- Cluster-scoped resources (ClusterRoles, ClusterRoleBindings, CRDs) created by test setup scripts
- Chainsaw's own test namespaces — chainsaw automatically creates a namespace per test with a `chainsaw-` prefix (e.g., `chainsaw-targetallocator`, `chainsaw-tls-profile`)

**Reliable cleanup approach:**

```bash
# 1. Find and delete the chainsaw test namespace(s) for this test
#    Chainsaw prefixes namespaces with "chainsaw-" followed by the test name
kubectl get namespace | grep "chainsaw-<test-name>"
kubectl delete namespace chainsaw-<test-name> --ignore-not-found=true
kubectl wait --for=delete namespace/chainsaw-<test-name> --timeout=5m 2>/dev/null || true
```

Deleting the namespace cascades and removes all namespaced resources the test created — CRs, operator-managed Deployments, Services, ConfigMaps — regardless of how they were created (YAML, script, or operator reconciliation).

```bash
# 2. Read chainsaw-test.yaml to identify cluster-scoped resources created by the test
#    (ClusterRoles, ClusterRoleBindings, CRDs, etc.) and delete them explicitly.
#
#    IMPORTANT: use a test-specific label selector to avoid deleting cluster-scoped
#    resources that belong to other concurrent tests or parallel job runs.
#    First inspect what labels chainsaw has set on the resources:
kubectl get clusterrole,clusterrolebinding -l app.kubernetes.io/managed-by=chainsaw --show-labels 2>/dev/null | head -20
#    Chainsaw sets a per-namespace label — use it to scope the delete to this test only:
kubectl delete clusterrole,clusterrolebinding \
  -l app.kubernetes.io/managed-by=chainsaw \
  -l chainsaw.kyverno.io/test-namespace=chainsaw-<test-name> \
  --ignore-not-found=true
#    If that label is absent in the output above, fall back to the test-name label instead:
#    kubectl delete clusterrole,clusterrolebinding \
#      -l app.kubernetes.io/managed-by=chainsaw \
#      -l chainsaw.kyverno.io/test-name=<test-name> \
#      --ignore-not-found=true

# 3. If the test's script steps created additional resources (visible in chainsaw-test.yaml
#    script blocks), identify and delete those resources manually
```

```bash
# 4. Verify the namespace is gone before rerunning
kubectl get namespace | grep "chainsaw-<test-name>" && echo "WARNING: namespace still exists" || echo "Clean"
```

Read `chainsaw-test.yaml` for the failing test before cleanup — it tells you what namespaces, CRs, and cluster-scoped resources the test creates, which guides what to delete.

### OpenTelemetry Operator
```bash
# Use TEST_DIR resolved in Step 2 (e.g. tests/e2e/targetallocator)
# Declare TEST_DIR explicitly — each bash invocation starts a fresh shell.
TEST_DIR="<value resolved in Step 2>"
# Read the fetched step script (from Step 0) to check whether --selector is used in the chainsaw invocation.
# Example: grep -o '\-\-selector [^ ]*' /tmp/fetched-step-script.sh | awk '{print "--selector", $2}'
OTEL_SELECTOR=""  # set to "--selector <value>" if the original script uses one, otherwise leave empty
CHAINSAW_CMD="chainsaw test --skip-delete --quiet --report-name junit_rerun_otel --report-path ${ARTIFACT_DIR} --report-format XML"
CHAINSAW_CMD+=" --test-dir ${TEST_DIR}"
[[ -n "${OTEL_SELECTOR}" ]] && CHAINSAW_CMD+=" ${OTEL_SELECTOR}"
eval "$CHAINSAW_CMD"
```

### Tempo Operator
```bash
# Use TEST_DIR resolved in Step 2 (e.g. tests/e2e-openshift/tls-profile)
# Declare TEST_DIR explicitly — each bash invocation starts a fresh shell.
TEST_DIR="<value resolved in Step 2>"
# Re-export GOPATH so test helpers compiled by make build (Step 0b) are on PATH.
export GOPATH=/tmp/go GOBIN=/tmp/go/bin GOCACHE=/tmp/.cache/go-build
export PATH="/tmp/go/bin:${PATH}"
# Tempo always uses --config .chainsaw-openshift.yaml (visible in the fetched step script)
chainsaw test \
  --skip-delete \
  --config .chainsaw-openshift.yaml \
  --quiet \
  --report-name "junit_rerun_tempo" \
  --report-path "${ARTIFACT_DIR}" \
  --report-format XML \
  --test-dir "${TEST_DIR}"
```

### Disconnected (distributed-tracing-qe)
```bash
# Use TEST_DIR resolved in Step 2 (e.g. tests/e2e/disconnected-smoke)
# Declare TEST_DIR explicitly — each bash invocation starts a fresh shell.
TEST_DIR="<value resolved in Step 2>"
CHAINSAW_CMD="chainsaw test --skip-delete --quiet --report-name junit_rerun_disconnected --report-path ${ARTIFACT_DIR} --report-format XML"
CHAINSAW_CMD+=" --test-dir ${TEST_DIR}"
eval "$CHAINSAW_CMD"
```

### Tracing UI (Cypress)
```bash
export NO_COLOR=1
export CYPRESS_CACHE_FOLDER=/tmp/Cypress
npx cypress run \
  --browser chrome \
  --headless \
  --spec "tests/cypress/e2e/<spec-file>" \
  --reporter junit \
  --reporter-options "mochaFile=${ARTIFACT_DIR}/junit_rerun_cypress_run1.xml"
```

After the rerun, read the fresh JUnit XML (saved to `$ARTIFACT_DIR`) to check whether the test is:
- **Consistently failing** — same failure, same message → proceed to Step 4 (diagnose)
- **Passed on first rerun** — possible flakiness → do not stop here; run the test 3 more times (4 total reruns) to confirm and locate where the flakiness occurs (see below)
- **Fixed by environment reset** — only relevant if the test setup was stale

### Flakiness confirmation loop

If the test passes on the first rerun, run it 3 more times sequentially. Clean up test resources before each run (see above). Use a unique `--report-name` per run so the XMLs don't overwrite each other:

**OpenTelemetry Operator:**
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

  CHAINSAW_CMD="chainsaw test --skip-delete --quiet --report-name junit_rerun_otel_run${i} --report-path ${ARTIFACT_DIR} --report-format XML"
  CHAINSAW_CMD+=" --test-dir ${TEST_DIR}"
  [[ -n "${OTEL_SELECTOR}" ]] && CHAINSAW_CMD+=" ${OTEL_SELECTOR}"
  eval "$CHAINSAW_CMD"
done
```

**Tempo Operator** (always include `--config .chainsaw-openshift.yaml`; re-export GOPATH for stage or downstream tests):
```bash
# Each bash invocation starts a fresh shell — re-declare TEST_DIR from Step 2.
TEST_DIR="<value resolved in Step 2>"
for i in 2 3 4; do
  kubectl delete namespace chainsaw-<test-name> --ignore-not-found=true
  kubectl wait --for=delete namespace/chainsaw-<test-name> --timeout=5m 2>/dev/null || true
  kubectl delete clusterrole,clusterrolebinding \
    -l app.kubernetes.io/managed-by=chainsaw \
    -l chainsaw.kyverno.io/test-namespace=chainsaw-<test-name> \
    --ignore-not-found=true

  # Re-export GOPATH for Tempo stage/downstream so test helpers on /tmp/go/bin are accessible
  export GOPATH=/tmp/go GOBIN=/tmp/go/bin GOCACHE=/tmp/.cache/go-build
  export PATH="/tmp/go/bin:${PATH}"

  chainsaw test \
    --skip-delete \
    --config .chainsaw-openshift.yaml \
    --quiet \
    --report-name "junit_rerun_tempo_run${i}" \
    --report-path "${ARTIFACT_DIR}" \
    --report-format XML \
    --test-dir "${TEST_DIR}"
done
```

For Cypress:
```bash
for i in 2 3 4; do
  npx cypress run \
    --browser chrome \
    --headless \
    --spec "tests/cypress/e2e/<spec-file>" \
    --reporter junit \
    --reporter-options "mochaFile=${ARTIFACT_DIR}/junit_rerun_cypress_run${i}.xml"
done
```

**Disconnected (distributed-tracing-qe):**
```bash
# Each bash invocation starts a fresh shell — re-declare TEST_DIR from Step 2.
TEST_DIR="<value resolved in Step 2>"
for i in 2 3 4; do
  kubectl delete namespace chainsaw-<test-name> --ignore-not-found=true
  kubectl wait --for=delete namespace/chainsaw-<test-name> --timeout=5m 2>/dev/null || true
  kubectl delete clusterrole,clusterrolebinding \
    -l app.kubernetes.io/managed-by=chainsaw \
    -l chainsaw.kyverno.io/test-namespace=chainsaw-<test-name> \
    --ignore-not-found=true

  CHAINSAW_CMD="chainsaw test --skip-delete --quiet --report-name junit_rerun_disconnected_run${i} --report-path ${ARTIFACT_DIR} --report-format XML"
  CHAINSAW_CMD+=" --test-dir ${TEST_DIR}"
  eval "$CHAINSAW_CMD"
done
```

After all 4 runs, count how many passed vs failed. Record the pass/fail pattern (e.g., `PFPP`, `PPFP`). Then inspect the test source:
- Look for missing `wait` blocks between an action and an assertion
- Look for very short `timeout` values in chainsaw steps (e.g., `timeout: 30s` where the operator may take longer)
- Look for assertions that depend on ordering of concurrent resources
- For Cypress: look for missing `cy.wait()` or `cy.intercept()` before asserting UI state

If the failure is reproducible even 1 out of 4 runs, classify as `FLAKY` and proceed to Step 5c to fix it.

---

## Step 4 — Diagnose: Product Bug vs Test Issue

Read the failure message, rerun output, and test source files together. Then run the full operator diagnostics below before making any classification decision — the logs and resource status are the primary evidence.

### Operator Diagnostics

Run all of the following. Capture output that is relevant to the failure (errors, warnings, crash reasons, unexpected conditions) and include it in the bug report or analysis summary.

#### OpenTelemetry Operator

```bash
# Operator pod status and logs
oc get pods -n opentelemetry-operator-system
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --tail=150
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --previous --tail=50 2>/dev/null || true

# OpenTelemetryCollector instances across all namespaces
oc get opentelemetrycollectors --all-namespaces -o wide
oc get opentelemetrycollectors --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.conditions[*].type}={.status.conditions[*].status} {.status.conditions[*].message}{"\n"}{end}'

# Instrumentation, OpAMPBridge, TargetAllocator CRs
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

#### Tempo Operator

```bash
# Operator pod status and logs
oc get pods -n openshift-tempo-operator
oc logs -n openshift-tempo-operator deploy/tempo-operator-controller --tail=150
oc logs -n openshift-tempo-operator deploy/tempo-operator-controller --previous --tail=50 2>/dev/null || true

# TempoStack and TempoMonolithic instances across all namespaces
oc get tempostacks --all-namespaces -o wide 2>/dev/null || true
oc get tempostacks --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.conditions[*].type}={.status.conditions[*].status} {.status.conditions[*].message}{"\n"}{end}' 2>/dev/null || true
oc get tempomonolithics --all-namespaces -o wide 2>/dev/null || true

# Operand pods in the test namespace (query gateway, distributor, ingester, compactor, querier)
oc get pods -n <test-namespace> -o wide
oc describe pods -n <test-namespace> | grep -A10 -E 'Events:|Reason:|State:|Exit Code:|OOMKilled'

# Events in operator namespace and test namespace
oc get events -n openshift-tempo-operator --sort-by='.lastTimestamp' | tail -20
oc get events -n <test-namespace> --sort-by='.lastTimestamp' | tail -30

# Storage secret and object store config (common Tempo failure cause)
oc get secret -n <test-namespace> | grep -E 'minio|s3|gcs|azure|storage'

# CSV and subscription status
oc get csv -n openshift-tempo-operator -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase} — {.status.message}{"\n"}{end}'
oc get subscription -n openshift-tempo-operator -o jsonpath='{range .items[*]}{.metadata.name}: {.status.currentCSV} state={.status.state}{"\n"}{end}' 2>/dev/null || true
```

#### Cluster Observability Operator (COO)

```bash
# Operator pod status and logs (namespace depends on install mode)
COO_NS="$(oc get pods --all-namespaces -l app.kubernetes.io/name=observability-operator -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
if [ -z "${COO_NS}" ]; then
  COO_NS="openshift-cluster-observability-operator"
fi
oc get pods -n "${COO_NS}"
oc logs -n "${COO_NS}" deploy/observability-operator --tail=150 2>/dev/null || \
  oc logs -n "${COO_NS}" $(oc get pods -n "${COO_NS}" -l app.kubernetes.io/name=observability-operator -o name | head -1) --tail=150 2>/dev/null || true
oc logs -n "${COO_NS}" deploy/observability-operator --previous --tail=50 2>/dev/null || true

# UIPlugin CRs (controls Tracing UI console plugin registration)
oc get uiplugins --all-namespaces -o wide 2>/dev/null || true
oc get uiplugins --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.conditions[*].type}={.status.conditions[*].status} {.status.conditions[*].message}{"\n"}{end}' 2>/dev/null || true

# MonitoringStack CRs
oc get monitoringstacks --all-namespaces -o wide 2>/dev/null || true

# Console plugin registration status (Tracing UI)
oc get consoleplugin distributed-tracing-plugin -o jsonpath='{.status}{"\n"}' 2>/dev/null || true
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}' 2>/dev/null || true

# Events in COO namespace
oc get events -n "${COO_NS}" --sort-by='.lastTimestamp' | tail -20

# CSV and subscription status
oc get csv -n "${COO_NS}" -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase} — {.status.message}{"\n"}{end}'
```

#### Disconnected (distributed-tracing-qe)

The disconnected suite tests OTel and Tempo operators in a cluster with no direct internet access — images must be mirrored and catalog sources must reference an internal registry.

```bash
# Check both operator namespaces
oc get pods -n opentelemetry-operator-system
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --tail=100
oc get pods -n openshift-tempo-operator
oc logs -n openshift-tempo-operator deploy/tempo-operator-controller --tail=100

# Disconnected-specific: look for image pull failures (most common failure cause)
oc get pods --all-namespaces | grep -E 'ImagePullBackOff|ErrImagePull' 2>/dev/null || true

# Mirror configuration
oc get imagecontentsourcepolicies 2>/dev/null || true  # OCP 4.12 and earlier
oc get idms 2>/dev/null || true                         # ImageDigestMirrorSet (OCP 4.13+)
oc get itms 2>/dev/null || true                         # ImageTagMirrorSet

# Catalog sources (must be READY in disconnected clusters)
oc get catalogsource -n openshift-marketplace -o wide 2>/dev/null || true

# Events across all test namespaces (image pull errors, operator errors)
oc get events --all-namespaces --sort-by='.lastTimestamp' | grep -E 'Failed|Error|Warning' | tail -30
```

#### CRD and API availability check

```bash
# Verify all expected CRDs are present — missing CRDs cause many test failures
oc get crd | grep -E 'opentelemetry|tempo|observability|uiplugin|monitoringstack'

# Check operator API groups are registered
oc api-resources | grep -E 'opentelemetry|tempo|observability'
```

### Product Bug indicators
Classify as `PRODUCT_BUG` when the evidence shows the operator or operand itself misbehaved:
- Operator pod in `CrashLoopBackOff` or `OOMKilled`
- Operand resource (e.g., `TempoStack`, `OpenTelemetryCollector`) stuck in an error state not caused by the test YAML
- API object that the operator should have created is missing
- Image pull failure for an operand image referenced in the CSV
- CRD validation error rejecting a valid CR that worked in a prior release
- Timeout waiting for operator reconciliation when the operator logs show no activity

### Test Issue indicators
Classify as `TEST_ISSUE` when the test itself is wrong or stale:
- Hardcoded version string or image tag in the test YAML that doesn't match the currently installed operator version
- Wrong namespace name in an assertion (namespace changed between releases)
- Race condition: the test asserts a resource state before the operator has had time to act — look for very short `timeout` values in chainsaw steps or missing `wait` blocks
- Missing prerequisite in the test setup (e.g., a CRD that must be installed before the test runs but isn't part of the test's `setup` steps)
- Assertion checks a field or value that changed in the operator API (e.g., a renamed status condition)
- Cypress test references a UI element selector that changed in the console plugin

### Cluster Instability indicators
When MCP updating or operator restarts are present and tests pass cleanly on rerun, **do not classify as `CLUSTER_INSTABILITY` yet** — first rule out the operator itself as the source of API server pressure using the steps below. Only after confirming the operator is not looping can you attribute the instability to external infra churn.

Classify as `CLUSTER_INSTABILITY` when **all four** conditions hold:
- MCPs were updating (`UPDATING=True`, `UPDATED=False`) at the time of the original test run, **or** the operator pod shows `RESTARTS > 0` with liveness/readiness probe failures or leader election loss events correlated with MCP rollout timing
- Tests pass cleanly and quickly on all reruns (rerun duration significantly less than the original failing run)
- No code defect identified in either the operator or the test
- Operator debug logs (collected below) show **no tight reconciliation loops** driving excessive API server calls

`CLUSTER_INSTABILITY` takes precedence over `FLAKY`: if all 4 reruns pass cleanly AND the MCP or operator restart evidence points to infrastructure churn during the original run (and the operator is not looping), classify as `CLUSTER_INSTABILITY`, not `FLAKY`. Proceed to Step 5d instead of Step 5c.

#### Ruling out operator-caused API server pressure

Operator reconciliation loops — where the operator continuously re-queues the same object without back-off — can themselves drive enough API server load to cause liveness probe timeouts and leader election flaps, which looks identical to external infra churn. Check this before concluding the infrastructure is at fault.

**Step 1 — Enable debug logging on the operator CSV**

Patch the operator CSV to add `--zap-log-level=debug`. This causes OLM to restart the operator pod with verbose reconciliation logging.

For the **OpenTelemetry Operator**:
```bash
# Filter by name AND Succeeded phase — during upgrades both old and new CSVs coexist in the namespace
CSV_NAME=$(oc get csv -n opentelemetry-operator-system --no-headers \
  | awk '/opentelemetry-operator/ && /Succeeded/ {print $1}' | head -1)
# Show current args to confirm --zap-log-level is present (it is set to 'info' by default)
oc get csv "${CSV_NAME}" -n opentelemetry-operator-system \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}'

# Find the 0-based index of the existing --zap-log-level arg and replace its value with debug
ZAP_IDX=$(oc get csv "${CSV_NAME}" -n opentelemetry-operator-system \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}' \
  | awk '/--zap-log-level/{print NR-1; exit}')
if [[ -z "${ZAP_IDX}" ]]; then echo "ERROR: --zap-log-level not found in CSV args"; exit 1; fi
oc patch csv "${CSV_NAME}" -n opentelemetry-operator-system --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args/${ZAP_IDX}\",\"value\":\"--zap-log-level=debug\"}]"
```

For the **Tempo Operator**:
```bash
CSV_NAME=$(oc get csv -n openshift-tempo-operator --no-headers \
  | awk '/tempo-operator/ && /Succeeded/ {print $1}' | head -1)
oc get csv "${CSV_NAME}" -n openshift-tempo-operator \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}'

ZAP_IDX=$(oc get csv "${CSV_NAME}" -n openshift-tempo-operator \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}' \
  | awk '/--zap-log-level/{print NR-1; exit}')
if [[ -z "${ZAP_IDX}" ]]; then echo "ERROR: --zap-log-level not found in CSV args"; exit 1; fi
oc patch csv "${CSV_NAME}" -n openshift-tempo-operator --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args/${ZAP_IDX}\",\"value\":\"--zap-log-level=debug\"}]"
```

Wait for the operator pod to restart with the new flag:
```bash
# OpenTelemetry
oc rollout status deploy/opentelemetry-operator-controller-manager -n opentelemetry-operator-system --timeout=3m

# Tempo
oc rollout status deploy/tempo-operator-controller -n openshift-tempo-operator --timeout=3m
```

**Step 2 — Collect debug logs and check for reconciliation loops**

Let the operator run for 2–3 minutes, then collect logs:

```bash
# OpenTelemetry — capture last 500 lines of debug output
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --tail=500 \
  | grep -E '"reconcileID"|"Reconciling"|"requeue"|"error"' \
  | head -100

# Tempo
oc logs -n openshift-tempo-operator deploy/tempo-operator-controller --tail=500 \
  | grep -E '"reconcileID"|"Reconciling"|"requeue"|"error"' \
  | head -100
```

**Indicators of a reconciliation loop causing pressure:**
- The same resource name (`"name":"<cr-name>"`) appears in `Reconciling` log lines many times within seconds (more than once every 2–3 seconds is a strong signal)
- `"requeue"` entries at very short intervals (sub-second) with no intervening `"Reconciling finished"` or success message
- `controller-runtime` lines reporting queue depth growing (`"queue depth": N` increasing over time)
- Rate-limiting warnings: `"controller-runtime/controller"` messages like `"Reconciler error"` followed immediately by rapid requeue

**Indicators that the operator is healthy (no loop):**
- `Reconciling` log lines appear infrequently (one reconcile per object per event, with gaps of 10+ seconds between repeated reconciles for the same object)
- No `requeue` entries on short intervals
- Log volume is low and stable

If a reconciliation loop is found, reclassify as `PRODUCT_BUG` (the operator is mis-behaving under load) and write a bug report in Step 5b. Include the relevant log lines as evidence.

When genuinely ambiguous, gather more cluster evidence before deciding. Explain your reasoning explicitly in the output.

---

## Step 5a — If TEST_ISSUE: Fix and Export

Apply the **minimal** change to make the test correct. Avoid refactoring or improving unrelated parts of the test — a focused, small diff is easier to review and merge.

**For chainsaw tests:**
- Edit `chainsaw-test.yaml`, `assert.yaml`, resource manifests, or other YAML files in the test folder
- Common fixes: update image/version references, fix namespace, add a `wait` step before an assertion, correct a changed field name in assertions

**For Cypress tests:**
- Edit the `.cy.js` / `.cy.ts` spec file
- Common fixes: update CSS selector, fix a changed route or API endpoint, add a `cy.wait()` for async operations

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
- Operator: <OpenTelemetry Operator / Tempo Operator / Tracing UI>
- Namespace: <opentelemetry-operator-system | openshift-tempo-operator>
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

**For chainsaw tests:**
- If a step asserts state immediately after a resource is applied, add an explicit `wait` step using `chainsaw wait` or a `sleep` in a script step before the assertion
- If a `timeout` is too short, increase it to give the operator time to reconcile (common fix: `30s` → `2m`)
- If two resources are created concurrently and one depends on the other, reorder the steps to create the dependency first

Example — adding a wait step in `chainsaw-test.yaml`:
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

**For Cypress tests:**
- Add `cy.intercept()` to wait for the relevant API call before asserting
- Use `cy.findByText(...).should('be.visible')` with a custom timeout rather than asserting immediately
- Replace `cy.wait(<ms>)` (fixed-time sleep) with a condition-based wait when possible

After editing, copy changed files to `${ARTIFACT_DIR}/test-fixes/` with the same structure as Step 5a. Write `CHANGES.md` using the same template, and include the pass/fail pattern from the 4 rerun runs as evidence.

---

## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Do not attempt to fix the operator or test code. Write `${ARTIFACT_DIR}/cluster-instability-report.md`:

````markdown
# Cluster Instability Report

## Summary
<one-sentence description — e.g. "Operator restarted 3 times due to MCP rollout during the test run, causing spurious failures.">

## Affected Tests
| Suite | Test Case | Original Duration | Rerun Duration |
|---|---|---|---|
| <suite> | <test-case> | <Xs> | <Ys> |

## Root Cause
<What was happening on the cluster: MCP updates, node evictions, API server timeouts, operator pod CrashLoopBackOff / leader election loss. Include the MCP status snapshot captured in Step 0a.>

## Evidence

### MachineConfigPool status at triage time
```text
<oc get machineconfigpools output showing UPDATING=True or UPDATED=False>
```

### Operator pod restarts and events
```text
<relevant pod status, events, liveness probe failures, leader election lines>
```

## Rerun Results
All reruns passed cleanly — failures are not reproducible outside the original cluster instability window.

## Recommendation
Rerun the CI job. The failures are caused by cluster infrastructure churn, not by a product or test defect.
````

---

## Step 6 — Write Analysis Summary

Write `${ARTIFACT_DIR}/qe-agent-analysis.md` **immediately after each test is diagnosed** (after Step 4/5a/5b/5c/5d is complete for that test), not at the very end. If multiple tests are being investigated sequentially, write an initial draft after the first test is diagnosed and overwrite it after each subsequent test is diagnosed. This ensures the report is present in `${ARTIFACT_DIR}` — and therefore uploaded by the sidecar — even if the session is interrupted before all tests are fully processed.

Do not wait for background flakiness confirmation runs to finish before writing the first draft. Write a partial entry for in-progress tests (e.g. "Rerun 1: PASS — flakiness confirmation in progress") and overwrite with final results when the runs complete.

Throughout the run, note any place where a skill step was wrong, incomplete, or had to be adapted — commands that failed, assumptions that did not hold, diagnostics that were decisive but not mentioned in the skill, or steps that wasted time. Record all of these in the **Skill Improvement Recommendations** section of the analysis. This feedback is used to improve the skill so future runs are faster, cheaper, and more accurate. If the skill worked as written with no deviations, write "None."

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
<!-- Record any deviation from the skill steps here — wrong commands, missing steps, steps that needed adaptation, or better approaches discovered during this run. Omit this section if the skill worked as written. -->
<If the skill steps were followed exactly and worked correctly>: None.
<Otherwise, one bullet per finding>:
- **Step <N> — <short title>**: <What the skill said to do> → <What actually worked / what was wrong and why>. Suggested fix: <concrete change to the skill>.

Examples of what belongs here:
- A command in the skill failed and had to be adapted (wrong flag, missing argument, changed API)
- A diagnostic the skill did not mention turned out to be the decisive evidence
- A step the skill prescribed was unnecessary or wasted significant time
- The cleanup approach did not work and a different method had to be used
- An assumption in the skill (namespace, resource name, container index) did not hold for this operator version
````

---

## Notes for CI context

- The cluster is already provisioned and the operator is already installed — do not reinstall the operator
- `$KUBECONFIG` is set and points to the test cluster
- `oc` and `kubectl` are available
- `chainsaw` is available in PATH
- The test repo is set up by Step 0b using commands from the fetched step script — the repo path is the destination shown in the script (e.g., `/tmp/opentelemetry-tests`, `/tmp/tempo-tests`). The qe-agent runs in a fresh pod so `/tmp/` is always empty at start; Step 0b populates it
- All output files must go to `$ARTIFACT_DIR` (uploaded to GCS by the sidecar) or `$SHARED_DIR` (accessible to other steps)
- This step runs `best_effort: true` — always exit 0 even if analysis is incomplete
