---
name: tracing-ui-qe-agent
description: Use this skill to analyze failing CI tests for the OpenShift Distributed Tracing UI console plugin, rerun the specific failing tests (Cypress-based, junit_distributed-tracing-console-plugin* prefix), diagnose whether the failure is a product bug or a test that needs fixing, apply fixes to test source files when needed, and export results to the artifact directory. Trigger whenever $SHARED_DIR/qe-agent-context.json is present with has_test_failures=true for Tracing UI tests, or when an engineer asks to debug, rerun, or fix failing Tracing UI or console plugin QE tests.
---

# Tracing UI QE Agent — Test Failure Triage and Fix

This skill drives an agentic loop that takes failing CI test results for the Distributed Tracing Console Plugin, reruns the failing tests, determines root cause (product bug vs broken test), and either fixes the test or writes a structured bug report.

## Test Infrastructure Overview

| JUnit prefix | Suite | Framework | Repo |
|---|---|---|---|
| `junit_distributed-tracing-console-plugin*` | Tracing UI (Cypress) | Cypress/npm | `https://github.com/openshift/distributed-tracing-console-plugin` |

---

## Step 0 — Read Setup Context and Fetch the Step Script

Read `${SHARED_DIR}/qe-agent-context.json`. The test step writes it at exit time:

```json
{
  "step_script_ref": "distributed-tracing/tests/tracing-ui/distributed-tracing-tests-tracing-ui-commands.sh",
  "has_test_failures": true,
  "env": {}
}
```

- `step_script_ref` — path relative to `ci-operator/step-registry/` in the openshift/release repo
- `env` — runtime env var values that were injected at job time and are needed to reproduce setup (e.g. branch names, image refs); most steps have an empty `env`

Construct the raw GitHub URL and fetch the script:

```text
https://raw.githubusercontent.com/openshift/release/main/ci-operator/step-registry/<step_script_ref>
```

Read the script carefully. It is divided into two logical sections:
1. **Setup** — everything before the `npx cypress run` commands: cloning repos, `oc apply`, `kubectl create`, `npm install`, IDP/htpasswd setup, env variable setup
2. **Test execution** — the `npx cypress run` invocations themselves

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

## Step 0b — Re-establish the Test Environment

Export any env vars from the `env` field, then **run the setup section of the fetched script** — the commands up to (but not including) the first `npx cypress run` invocation.

Required adaptations:

| Script pattern | Adaptation |
|---|---|
| `cp -R /tmp/<name>` (image mount) | Replace with `git clone <repo> <dest>` — find the repo URL from the step script or the CI config |
| `kubectl create -f <url>` (CRDs) | Use `kubectl apply -f <url>` — `create` fails if the CRD exists from the prior run |
| `oc patch csv ...` | Skip — the operator is already patched; verify with `oc get csv -n openshift-cluster-observability-operator` |
| `$SKIP_TESTS` block | Skip entirely — `$SKIP_TESTS` is unset in the qe-agent pod |
| htpasswd / oauth setup | Check if the secret already exists before creating: `oc get secret htpass-secret -n openshift-config`. Skip creation if it does. Similarly, only patch oauth if the htpasswd IDP is not already configured |

After setup, `cd` into the repo directory and proceed with Steps 1–6.

If `qe-agent-context.json` does not exist, infer the suite from the JUnit file name prefix (`junit_distributed-tracing-console-plugin*` → Tracing UI) and skip the rerun — proceed directly to diagnosis from the JUnit content and cluster state.

## Step 1 — Parse JUnit XMLs and Identify Failures

Read all JUnit XML files from `${SHARED_DIR}/qe-agent-junit-*.xml` (flat files copied by the test step trap function).

For each XML file, extract:
- **Suite name** (`name` attribute on `<testsuite>`)
- **Failed test cases**: `<testcase>` elements that contain a `<failure>` or `<error>` child
- **Failure message**: the `message` attribute and text body of `<failure>`/`<error>`
- **Stack trace / details**: the full text content of the failure element

Group failures by suite so you process each suite's failures together.

If no `${SHARED_DIR}/qe-agent-junit-*.xml` files are found, exit with a clear message — the test steps did not run or produced no results.

### High-failure triage: more than 5 failures total

When the total number of failing test cases is more than 5, it is very likely that all failures share a single root cause (console plugin not loaded, auth failure, UI not responding, network error) rather than being independent bugs.

**What to do:**

1. **Look for a common pattern** across the failure messages. Common indicators:
   - All messages contain the same error string (e.g., `Cannot read properties of null`, `element not found`, `401 Unauthorized`, `plugin not enabled`)
   - All tests fail at the same Cypress command (e.g., `cy.visit`, `cy.get`, `cy.findByText`)
   - Failure times are clustered tightly — the console plugin may not have loaded before tests started

2. **If a clear pattern exists**: pick the **simplest failing test** as the representative case. Proceed with Steps 2–5 for that one test only, skipping the rest.

3. **If no clear pattern**: the failures are likely independent. Fall back to processing each failure individually, cap at 3 tests, and note this in the summary.

Write the pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.

---

## Step 2 — Locate Test Source Files

The failing test name maps to a `describe` + `it` block inside `.cy.js` or `.cy.ts` files under `tests/cypress/e2e/`. Use `grep -r "<test-name>"` to locate the spec file.

For Cypress tests, the key files are:
- The spec file (`.cy.js` or `.cy.ts`) — contains the `describe`/`it` blocks and all test logic
- `cypress.config.ts` or `cypress.json` — Cypress configuration (base URL, timeouts, etc.)
- Page object or helper files imported by the spec

Use the destination path from the fetched step script as your repo root — do not guess or scan `/tmp/` broadly.

---

## Step 3 — Rerun the Failing Tests

Rerun only the specific failing test spec, not the entire Cypress suite.

### Tracing UI (Cypress) — first rerun

No namespace cleanup is needed for Cypress tests (they do not create chainsaw namespaces). However, verify the console plugin is still registered and the htpasswd IDP is still active before rerunning:

```bash
# Verify console plugin is registered
oc get consoleplugin distributed-tracing-plugin -o jsonpath='{.status}{"\n"}' 2>/dev/null || true
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}' 2>/dev/null || true

# Verify htpasswd IDP is configured
oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}{"\n"}' 2>/dev/null || true
```

Then run the failing spec:

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
- **Fixed by environment reset** — only relevant if the console plugin or auth state was stale

### Flakiness confirmation loop

If the test passes on the first rerun, run it 3 more times sequentially. Use a unique `mochaFile` per run so the XMLs don't overwrite each other:

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

After all 4 runs, count how many passed vs failed. Record the pass/fail pattern (e.g., `PFPP`, `PPFP`). Then inspect the test source:
- Look for missing `cy.intercept()` before asserting UI state after an API call
- Look for `cy.get()` without waiting for an element to be visible
- Look for missing `cy.wait()` or condition-based waits before asserting dynamic content
- Check if the test uses a fixed URL path that may have changed in the plugin

If the failure is reproducible even 1 out of 4 runs, classify as `FLAKY` and proceed to Step 5c to fix it.

---

## Step 4 — Diagnose: Product Bug vs Test Issue

Read the failure message, rerun output, and test source files together. Then run the full operator diagnostics below before making any classification decision — the logs and resource status are the primary evidence.

### Cluster Observability Operator Diagnostics

```bash
# Auto-detect COO namespace (depends on install mode)
COO_NS="$(oc get pods --all-namespaces -l app.kubernetes.io/name=observability-operator -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
if [ -z "${COO_NS}" ]; then
  COO_NS="openshift-cluster-observability-operator"
fi

# Operator pod status and logs
oc get pods -n "${COO_NS}"
oc logs -n "${COO_NS}" deploy/observability-operator --tail=150 2>/dev/null || \
  oc logs -n "${COO_NS}" "$(oc get pods -n "${COO_NS}" -l app.kubernetes.io/name=observability-operator -o name | head -1)" --tail=150 2>/dev/null || true
oc logs -n "${COO_NS}" deploy/observability-operator --previous --tail=50 2>/dev/null || true

# UIPlugin CRs (controls Tracing UI console plugin registration)
oc get uiplugins --all-namespaces -o wide 2>/dev/null || true
oc get uiplugins --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.conditions[*].type}={.status.conditions[*].status} {.status.conditions[*].message}{"\n"}{end}' 2>/dev/null || true

# MonitoringStack CRs
oc get monitoringstacks --all-namespaces -o wide 2>/dev/null || true

# Console plugin registration status
oc get consoleplugin distributed-tracing-plugin -o jsonpath='{.status}{"\n"}' 2>/dev/null || true
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}' 2>/dev/null || true

# Events in COO namespace
oc get events -n "${COO_NS}" --sort-by='.lastTimestamp' | tail -20

# CSV and subscription status
oc get csv -n "${COO_NS}" -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase} — {.status.message}{"\n"}{end}'
```

### CRD and API availability check

```bash
# Missing CRDs cause plugin registration failures
oc get crd | grep -E 'observability|uiplugin|monitoringstack'
oc api-resources | grep observability
```

### Product Bug indicators
Classify as `PRODUCT_BUG` when the evidence shows the operator, plugin, or console itself misbehaved:
- COO operator pod in `CrashLoopBackOff` or `OOMKilled`
- `UIPlugin` stuck in an error state (not caused by the test YAML)
- Console plugin not loaded after being registered (consoleplugin status shows error)
- API endpoint returns unexpected error codes that the test cannot control
- Console route is inaccessible or returns 5xx errors

### Test Issue indicators
Classify as `TEST_ISSUE` when the test itself is wrong or stale:
- CSS selector in `cy.get()` that no longer matches the current plugin UI (element renamed or restructured)
- Route or URL path that changed in the console plugin between releases
- Test references a feature flag or UI element that was removed or renamed
- Test hardcodes a resource name or namespace that changed between releases
- Missing `cy.intercept()` or `cy.wait()` for an async operation (network request, dynamic element)

### Cluster Instability indicators

Before classifying as `CLUSTER_INSTABILITY`, rule out a tight COO reconciliation loop. Enable debug logging first:

```bash
COO_NS="$(oc get pods --all-namespaces -l app.kubernetes.io/name=observability-operator \
  --no-headers -o custom-columns='NS:.metadata.namespace' 2>/dev/null | head -1)"
CSV=$(oc get csv -n "${COO_NS}" --no-headers \
  | awk '/cluster-observability-operator/ && /Succeeded/{print $1}' | head -1)
IDX=$(oc get csv "$CSV" -n "${COO_NS}" \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}' \
  | awk '/--zap-log-level/{print NR-1; exit}')
if [[ -z "$IDX" ]]; then echo "WARNING: --zap-log-level not found in COO CSV args"; else
  oc patch csv "$CSV" -n "${COO_NS}" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args/${IDX}\",\"value\":\"--zap-log-level=debug\"}]"
  oc rollout status deploy/observability-operator -n "${COO_NS}" --timeout=3m
fi
oc logs -n "${COO_NS}" deploy/observability-operator --tail=500 \
  | grep -E '"reconcileID"|"Reconciling"|"requeue"|"error"' | head -100
```

A reconciliation loop (same MonitoringStack reconciled >1/2s, rapid sub-second `requeue` entries) reclassifies to `PRODUCT_BUG`. Classify as `CLUSTER_INSTABILITY` only when **all four** hold: (1) MCPs were updating or COO showed probe-failure restarts correlated with MCP rollout at original run time; (2) tests pass cleanly on all 4 reruns; (3) no fixable test defect — if any selector, wait, or assertion would fail under foreseeable cluster load, that is a `TEST_ISSUE`; (4) no tight reconciliation loop confirmed above. `CLUSTER_INSTABILITY` takes precedence over `FLAKY` when all four hold. Proceed to Step 5d.

When genuinely ambiguous, gather more cluster evidence before deciding. Explain your reasoning explicitly in the output.

---

## Step 5a — If TEST_ISSUE: Fix and Export

Apply the **minimal** change to make the test correct. Edit the `.cy.js` or `.cy.ts` spec file. Common fixes:
- Update a CSS selector to match the current plugin UI
- Fix a changed route or API endpoint path
- Add a `cy.wait()` for an async operation that isn't awaited
- Fix a hardcoded resource name or namespace

After editing, copy only the changed files to `${ARTIFACT_DIR}/test-fixes/` **preserving the directory path relative to the repo root**:

```bash
# Example: tests/cypress/e2e/tracing.cy.js was fixed
dest="${ARTIFACT_DIR}/test-fixes/tests/cypress/e2e"
mkdir -p "${dest}"
cp tests/cypress/e2e/tracing.cy.js "${dest}/"
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
- `tests/cypress/e2e/<spec-file>.cy.js`

## Verification
Rerun result after fix: [PASS / FAIL / not re-verified]
```

---

## Step 5b — If PRODUCT_BUG: Write Bug Report

Do not attempt to fix the plugin or operator code. Instead, write `${ARTIFACT_DIR}/bug-report.md`:

````markdown
# Product Bug Report

## Summary
<one-sentence description of the bug>

## Affected component
- Operator: Cluster Observability Operator / Distributed Tracing Console Plugin
- Namespace: <COO namespace>
- Failing test: <suite / test case>

## Reproduction
1. <Step-by-step reproduction based on what the test does>

## Observed behavior
<What happened — include the exact failure message from JUnit and the Cypress error>

## Expected behavior
<What should have happened>

## Evidence
### Operator logs
```text
<relevant COO log lines>
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

Common Cypress fixes:
- Add `cy.intercept()` to wait for the relevant API call before asserting UI state
- Use `cy.findByText(...).should('be.visible')` with a custom timeout rather than asserting immediately
- Replace `cy.wait(<ms>)` (fixed-time sleep) with a condition-based wait when possible

Example — waiting for an API response before asserting a table:
```javascript
cy.intercept('GET', '/api/v1/traces*').as('getTraces')
cy.visit('/monitoring/traces')
cy.wait('@getTraces')
cy.findByText('No traces found').should('not.exist')
```

After editing, copy changed files to `${ARTIFACT_DIR}/test-fixes/` (same structure as Step 5a). Write `CHANGES.md` with the pass/fail pattern from the 4 reruns as evidence.

---

## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Write `${ARTIFACT_DIR}/cluster-instability-report.md` with: a one-sentence summary; a table of affected tests (suite / test case / original duration / rerun duration); root cause (MCP updates, node evictions, COO pod restarts — include the MCP status snapshot from Step 0a); evidence (MCP output, relevant pod events); and a recommendation to rerun the CI job.

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

<Two to three sentences explaining the reasoning. Reference specific Cypress errors, console plugin status, COO log lines, or MCP status that led to this conclusion.>

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

- The cluster is already provisioned and the COO and Tracing UI console plugin are already installed — do not reinstall them
- The test repo is set up by Step 0b using commands from the fetched step script. The qe-agent runs in a fresh pod so `/tmp/` is always empty at start; Step 0b populates it
- `$KUBECONFIG` is set and points to the test cluster; `oc`, `kubectl`, and `npm`/`npx` are available in PATH
- Cypress screenshots and videos are binary artifacts — do **not** copy them to `$SHARED_DIR` (its 1 MiB Secret limit would be exceeded immediately). Only JUnit XML reports are safe to copy
- All output files must go to `$ARTIFACT_DIR` (uploaded to GCS by the sidecar) or `$SHARED_DIR` (accessible to other steps)
- This step runs `best_effort: true` — always exit 0 even if analysis is incomplete
