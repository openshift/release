---
name: tracing-ui
description: Use this skill to analyze failing CI tests for the OpenShift Distributed Tracing UI console plugin (Cypress, junit_distributed-tracing-console-plugin* prefix) - rerun them, diagnose product bug vs test issue vs job configuration, fix test files when needed, and export results. Trigger when $SHARED_DIR/qe-agent-context.json has has_test_failures=true for Tracing UI tests, or when an engineer asks to debug, rerun, or fix failing Tracing UI QE tests.
---

# Tracing UI QE Agent — Test Failure Triage and Fix

This skill reruns failing CI tests for the Distributed Tracing Console Plugin, determines the root cause, and either fixes the test, writes a bug report, or recommends a job config change.

## Test Infrastructure Overview

| JUnit prefix | Suite | Framework | Repo |
|---|---|---|---|
| `junit_distributed-tracing-console-plugin*` | Tracing UI (Cypress) | Cypress/npm | `https://github.com/openshift/distributed-tracing-console-plugin` |

---

## Step 0 — Read Setup Context and Fetch the Step Script

Read `${SHARED_DIR}/qe-agent-context.json`, written by the test step at exit:

```json
{
  "step_script_ref": "distributed-tracing/tests/tracing-ui/upstream/distributed-tracing-tests-tracing-ui-upstream-commands.sh",
  "has_test_failures": true,
  "env": {
    "CYPRESS_SKIP_TESTS": "-Lightspeed"
  }
}
```

- `step_script_ref` — path relative to `ci-operator/step-registry/` in openshift/release
- `env` — job-time env values needed to reproduce setup; `CYPRESS_SKIP_TESTS` is the job's `@cypress/grep` pattern (empty = all tests), applied to reruns in Step 3

Fetch `https://raw.githubusercontent.com/openshift/release/main/ci-operator/step-registry/<step_script_ref>`. Everything before the first `npx cypress run` / `npm run` is **setup** (repo clone, IDP/htpasswd, env vars, `npm install`); the rest is **test execution**.

## Step 0a — Verify Cluster Stability

Before running any prerequisites setup or test reruns, confirm the cluster is stable. The original CI test step may have applied resources that triggered MachineConfig updates — running tests while nodes are updating causes spurious failures.

```bash
oc get machineconfigpools.machineconfiguration.openshift.io
```

For each MachineConfigPool, all of the following must be true before proceeding:
- `UPDATED` = `True`
- `UPDATING` = `False`
- `DEGRADED` = `False`

**If any pool is not ready**, wait and recheck every 60 seconds:

```bash
# Wait until all MCPs are updated, not updating, and not degraded.
# Split into two 10-minute phases to stay within the Bash tool's timeout limit.
# Phase 1: wait up to 10 minutes
deadline=$((SECONDS + 600))
while oc get machineconfigpools.machineconfiguration.openshift.io \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Updated")].status}{" "}{.status.conditions[?(@.type=="Updating")].status}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' \
    | grep -qvE '^True False False$'; do
  echo "MCPs not ready yet, waiting 60s..."
  if (( SECONDS >= deadline )); then
    echo "Phase 1 timeout — MCPs still not ready after 10 minutes. Continuing in phase 2."
    oc get machineconfigpools.machineconfiguration.openshift.io
    break
  fi
  sleep 60
  oc get machineconfigpools.machineconfiguration.openshift.io
done
```

If the first phase did not converge (the loop exited via the `break`), run a second Bash invocation to continue waiting:

```bash
# Phase 2: wait up to 10 more minutes (total 20 minutes across both phases)
deadline=$((SECONDS + 600))
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

Export the `env` vars, then run the script's setup section (up to the first `npx cypress run`) with these adaptations:

| Script pattern | Adaptation |
|---|---|
| `cp -R /tmp/<name>` (image mount) | `git clone <repo> <dest>` — repo URL from the step script or CI config |
| `kubectl create -f <url>` (CRDs) | `kubectl apply -f <url>` — `create` fails if the CRD exists |
| `oc patch csv ...` | Skip — already patched; verify with `oc get csv -n openshift-cluster-observability-operator` |
| `CYPRESS_SKIP_TESTS` block | Keep it; reruns use it (Step 3) |
| htpasswd / oauth setup | Create the secret only if `oc get secret htpass-secret -n openshift-config` fails; patch oauth only if the htpasswd IDP is missing |
| Operator installs / OperatorGroups | Already installed by the original run — check `oc get csv -A`, do not reinstall. Check `oc get operatorgroup -n <ns>` before creating one; a second OperatorGroup fails the CSV ("csv created in namespace with multiple operatorgroups") |

Then continue with Steps 1–6 in the cloned repo. If `qe-agent-context.json` is missing, infer the suite from the JUnit prefix, skip the rerun, and diagnose from the JUnit content and cluster state.

## Step 1 — Parse JUnit XMLs and Identify Failures

Read `${SHARED_DIR}/qe-agent-junit-*.xml`. For each file extract the suite name (`<testsuite name>`), the failed `<testcase>` elements (those with a `<failure>` or `<error>` child), and the failure `message` and full text. Group failures by suite. If no files exist, exit with a clear message — the test step produced no results.

### High-failure triage: more than 5 failures total

More than 5 failures usually share one root cause (console plugin not loaded, auth failure, UI not responding, network error, or a failed `before` hook). Look for a common pattern: the same error string (`Cannot read properties of null`, `element not found`, `401 Unauthorized`, `plugin not enabled`), the same failing Cypress command (`cy.visit`, `cy.get`, `cy.findByText`), or tightly clustered failure times.

- **Clear pattern**: pick the simplest failing test as the representative and run Steps 2–5 for it only.
- **No clear pattern**: process failures individually, cap at 3 tests, and note this in the summary.

Write the pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.

---

## Step 2 — Locate Test Source Files

The repo root is the clone destination from the step script — do not scan `/tmp/` broadly. All tests are in one spec, `tests/e2e/dt-plugin-tests.cy.ts`: a single `describe` whose `before` hook installs/verifies the operators, sets up Lightspeed and creates the UIPlugin, then one `it` per capability. A `before` hook failure skips every test. Locate the `it` block with `grep -n "<test-name>"`. Supporting files under `tests/`: Cypress config, `cypress/support/` custom commands (e.g. `cy.runChainsawTest`), `views/` page objects, `fixtures/` chainsaw tests.

---

## Step 3 — Rerun the Failing Tests

Rerun only the failing test, selected by title with `@cypress/grep`. Each run first executes the whole `before` hook (several minutes, 15+ when installing operators), longer than the Bash tool's 10-minute timeout — use `run_in_background` and poll.

Before rerunning, inspect the RBAC test's `chainsaw-*` namespaces and `verify-traces-*` job pod logs if it failed (chainsaw runs with `--skip-delete`; the `before` hook removes them on the next run), and confirm the console plugin (Step 4 commands) and htpasswd IDP (`oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'`) are still in place.

```bash
cd "<repo root>/tests"
export NO_COLOR=1 CYPRESS_CACHE_FOLDER=/tmp/Cypress CYPRESS_SKIP_COO_INSTALL=true
# Fresh shell: also re-export the CYPRESS_* vars from the step script setup (base URL, login, kubeconfig, Lightspeed)
CYPRESS_SKIP_TESTS=$(jq -r '.env.CYPRESS_SKIP_TESTS // ""' "${SHARED_DIR}/qe-agent-context.json" 2>/dev/null)
GREP="<unique part of the failing test title>"
[[ -n "${CYPRESS_SKIP_TESTS}" ]] && GREP="${GREP}; ${CYPRESS_SKIP_TESTS}"
RUN=1
npx cypress run --browser chrome --headless --spec "e2e/dt-plugin-tests.cy.ts" \
  --env grep="${GREP}",grepOmitFiltered=true \
  --reporter junit --reporter-options "mochaFile=${ARTIFACT_DIR}/junit_rerun_cypress_run${RUN}.xml"
```

### Selecting what to rerun

- Keep `CYPRESS_SKIP_TESTS` in the grep (`;` separates patterns, `-` excludes): the `before` hook reads it too, e.g. `-Lightspeed` skips the Lightspeed install on OCP versions where Lightspeed is not published.
- Tests are order-dependent: `Capability:RBAC` creates the Tempo instances (`chainsaw-rbac / simplst`, `chainsaw-mmo-rbac / mmo-rbac`) and traces that every later test uses except `Capability:TLSCertRotation` and `Capability:Installation`. Include it for those tests (`GREP="Capability:RBAC; Capability:TraceLimits"`), otherwise the rerun fails on `input[placeholder="Select a Tempo instance"]`.
- For a `before` hook failure, set `GREP` to only the `CYPRESS_SKIP_TESTS` value (empty runs every test).
- `CYPRESS_SKIP_COO_INSTALL=true` skips the OperatorHub install path (`CYPRESS_COO_UI_INSTALL`, the job default). A passing rerun does not verify an install-path fix — mark it "not re-verified" in `CHANGES.md`.

Read the rerun JUnit XML:
- **Same failure** → Step 4
- **Passed** → possible flakiness; confirm with the loop below
- **Fixed by environment reset** — only if the console plugin or auth state was stale

### Flakiness confirmation loop

Run the rerun block 3 more times with `RUN=2`, `3` and `4` (one JUnit file each) and record the pass/fail pattern (e.g. `PFPP`). Look for missing `cy.intercept()` or condition-based waits before asserting UI state, `cy.get()` without a visibility wait, or a changed URL path. A failure in even 1 of 4 runs is `FLAKY` → Step 5c.

---

## Step 4 — Diagnose: Product Bug vs Test Issue

Run the diagnostics below before classifying — logs and resource status, read with the failure message and test source, are the primary evidence.

### Cluster Observability Operator Diagnostics

```bash
# Auto-detect COO namespace (depends on install mode)
COO_NS="$(oc get pods --all-namespaces -l app.kubernetes.io/name=observability-operator -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
COO_NS="${COO_NS:-openshift-cluster-observability-operator}"

# Operator pod status and logs
oc get pods -n "${COO_NS}"
oc logs -n "${COO_NS}" deploy/observability-operator --tail=150 2>/dev/null || true
oc logs -n "${COO_NS}" deploy/observability-operator --previous --tail=50 2>/dev/null || true

# UIPlugins (cluster-scoped; control console plugin registration) and MonitoringStacks
oc get uiplugins -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.conditions[*].type}={.status.conditions[*].status} {.status.conditions[*].message}{"\n"}{end}' 2>/dev/null || true
oc get monitoringstacks --all-namespaces -o wide 2>/dev/null || true

# Console plugin registration status
oc get consoleplugin distributed-tracing-console-plugin -o jsonpath='{.status}{"\n"}' 2>/dev/null || true
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}' 2>/dev/null || true

# Events and CSV status in the COO namespace
oc get events -n "${COO_NS}" --sort-by='.lastTimestamp' | tail -20
oc get csv -n "${COO_NS}" -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase} — {.status.message}{"\n"}{end}'
```

### CRD and API availability check

```bash
# Missing CRDs cause plugin registration failures
oc get crd | grep -E 'observability|uiplugin|monitoringstack'
oc api-resources | grep observability
```

### Operator catalog availability check

The `before` hook installs COO, OpenTelemetry, Tempo and Lightspeed from `redhat-operators`. Pre-GA OCP versions may not ship all of them yet; OperatorHub then never renders the install form (`[data-test="install-operator"]` times out). Check before blaming the test or product:

```bash
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
for pkg in cluster-observability-operator opentelemetry-product tempo-product lightspeed-operator; do
  echo "${pkg}: $(oc get packagemanifest "${pkg}" -n openshift-marketplace -o jsonpath='{.status.catalogSource}' 2>/dev/null || echo MISSING)"
done
```

A package missing from the catalog on a pre-GA OCP version is `JOB_CONFIG` (Step 5e): do not add catalog auto-detection or skip logic to the test (it would silently skip the capability where the operator must exist), and do not file a product bug.

### Product Bug indicators
Classify as `PRODUCT_BUG` when the operator, plugin, or console itself misbehaved:
- COO operator pod in `CrashLoopBackOff` or `OOMKilled`
- `UIPlugin` in an error state not caused by the test YAML
- Console plugin registered but not loaded (consoleplugin status shows error)
- API endpoints or the console route return unexpected errors or 5xx the test cannot control

### Test Issue indicators
Classify as `TEST_ISSUE` when the test itself is wrong or stale:
- Selector, route, UI element or feature flag that changed or was removed in the plugin
- Hardcoded resource name or namespace that changed between releases
- Missing `cy.intercept()` or `cy.wait()` for an async operation

### Cluster Instability indicators

Before classifying as `CLUSTER_INSTABILITY`, rule out a tight COO reconciliation loop with debug logging:

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

A reconciliation loop (same MonitoringStack reconciled >1/2s, rapid sub-second `requeue` entries) is a `PRODUCT_BUG`. Classify as `CLUSTER_INSTABILITY` (Step 5d; takes precedence over `FLAKY`) only when **all four** hold: (1) MCPs were updating, or COO had probe-failure restarts correlated with the MCP rollout, at original run time; (2) all 4 reruns pass cleanly; (3) no fixable test defect — a selector, wait, or assertion that would fail under foreseeable cluster load is a `TEST_ISSUE`; (4) no tight reconciliation loop.

When ambiguous, gather more evidence and explain your reasoning.

---

## Step 5a — If TEST_ISSUE: Fix and Export

Apply the **minimal** change that makes the test correct (selector, route, wait for an async operation, hardcoded name). The tests use Cypress 15: `cy.exec()` yields `{ exitCode, stdout, stderr }` (no `code` field).

Copy only the changed files to `${ARTIFACT_DIR}/test-fixes/`, **preserving the path relative to the repo root**:

```bash
dest="${ARTIFACT_DIR}/test-fixes/tests/e2e"
mkdir -p "${dest}"
cp tests/e2e/dt-plugin-tests.cy.ts "${dest}/"
```

Write `${ARTIFACT_DIR}/test-fixes/CHANGES.md`:

```markdown
> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.

# Test Fix Summary

## Failing test
<suite name> / <test case name>

## Root cause
<one paragraph explaining what was wrong in the test and why>

## Fix applied
<what was changed, which files, what specifically>

## Files changed
- `tests/e2e/dt-plugin-tests.cy.ts`

## Verification
Rerun result after fix: [PASS / FAIL / not re-verified]
```

---

## Step 5b — If PRODUCT_BUG: Write Bug Report

Do not fix plugin or operator code; write `${ARTIFACT_DIR}/bug-report.md`:

````markdown
> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.

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

Then write `${ARTIFACT_DIR}/jira-payload.json` for automated Jira filing, converting the bug report to **Jira wiki notation**: `# `/`## `/`### ` → `h1. `/`h2. `/`h3. `, `**bold**` → `*bold*`, `` `code` `` → `{{code}}`, ` ```text ... ``` ` → `{code:title=text}...{code}`, `- item` → `* item`, `1. item` → `# item`, `> quote` → `bq. quote`.

Write the JSON using `jq` for safe escaping:

```bash
_SUMMARY="[qe-agent] <one-sentence summary from the bug report>"
# Summary must be ≤ 255 characters
_SUMMARY="${_SUMMARY:0:255}"

_DESCRIPTION="<full bug report content converted to Jira wiki notation>"

jq -n \
  --arg summary "${_SUMMARY}" \
  --arg description "${_DESCRIPTION}" \
  --arg severity "<Critical / Major / Minor>" \
  '{summary: $summary, description: $description, severity: $severity}' \
  > "${ARTIFACT_DIR}/jira-payload.json"
```

The description must NOT contain raw credentials, tokens, passwords, or SHA-256 digests — redact with `[REDACTED]` if any appear in the evidence.

---

## Step 5c — If FLAKY: Fix and Export

Fix the race itself, not with blanket retries. Typical fixes: `cy.intercept()` plus `cy.wait('@alias')` before asserting UI state after an API call, `.should('be.visible')` with a timeout instead of an immediate assertion, and condition-based waits instead of `cy.wait(<ms>)`. Export the changed files and `CHANGES.md` as in Step 5a, with the 4-run pass/fail pattern as evidence.

---

## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Write `${ARTIFACT_DIR}/cluster-instability-report.md` with: a one-sentence summary; a table of affected tests (suite / test case / original duration / rerun duration); root cause (MCP updates, node evictions, COO pod restarts — include the MCP status snapshot from Step 0a); evidence (MCP output, relevant pod events); and a recommendation to rerun the CI job. Begin it with the same AI-Generated Content banner as the other reports.

---

## Step 5e — If JOB_CONFIG: Recommend a Job Configuration Change

The test and product are fine, but the job needs something this cluster cannot provide (typically an operator not yet published for this OCP version). Do not modify the tests or write `jira-payload.json`. In `qe-agent-analysis.md`, give the missing package, OCP version and catalog evidence, and recommend the config change. For Lightspeed, add `CYPRESS_SKIP_TESTS: -Lightspeed` to the e2e `env` in `ci-operator/config/openshift/distributed-tracing-console-plugin/<variant>.yaml`; the spec then skips the Lightspeed install, setup and test. If COO, OpenTelemetry or Tempo is missing, recommend disabling or re-pointing the job instead.

---

## Step 6 — Write Analysis Summary

Write `${ARTIFACT_DIR}/qe-agent-analysis.md` after each diagnosis and overwrite it for later tests, with partial entries for in-progress flakiness runs ("Rerun 1: PASS — confirmation in progress"). Record deviations from the skill steps under **Skill Improvement Recommendations**.

````markdown
> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.

# QE Agent Analysis

## Failed Tests
| Suite | Test Case | JUnit File |
|---|---|---|
| <suite> | <test-case> | <xml-filename> |

## Rerun Result
<still failing / passed on rerun (flaky) / passed cleanly (cluster instability) / not rerun>

## Diagnosis
**<PRODUCT_BUG | TEST_ISSUE | FLAKY | CLUSTER_INSTABILITY | JOB_CONFIG>**

<Two to three sentences explaining the reasoning. Reference specific Cypress errors, console plugin status, COO log lines, catalog or MCP status that led to this conclusion.>

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
<If JOB_CONFIG>: No test or product change. Recommended job config change: <exact env/config change and file>.

## Evidence Sources
- JUnit XML: `<filename>` — failure message at line <N>
- Operator logs: `<namespace>/<deployment>` — <relevant log excerpt>
- Cluster state: <MCP status / CRD or catalog availability / pod status>
- Test source: `<file-path>` — <what was found>

## Skill Improvement Recommendations
<!-- Record deviations from the skill steps: commands that failed and had to be adapted, decisive diagnostics the skill did not mention, steps that were unnecessary or slow, cleanup that did not work, or assumptions (namespace, resource name, container index) that did not hold. -->
<If the skill steps were followed exactly and worked as written>: None.
<Otherwise, one bullet per finding>:
- **Step <N> — <short title>**: <What the skill said to do> → <What actually worked / what was wrong and why>. Suggested fix: <concrete change to the skill>.
````

---

## Notes for CI context

- The cluster is already provisioned with COO and the Tracing UI console plugin installed — do not reinstall them
- The qe-agent runs in a fresh pod, so `/tmp/` is empty at start; Step 0b clones the test repo there
- `$KUBECONFIG` points to the test cluster; `oc`, `kubectl`, `jq` and `npm`/`npx` are in PATH
- Do **not** copy Cypress screenshots or videos to `$SHARED_DIR` (1 MiB Secret limit); only JUnit XML is safe there. Write all output to `$ARTIFACT_DIR` (uploaded to GCS) or `$SHARED_DIR` (shared with other steps)
- **Namespace restriction**: You MUST NOT access, read, list, or modify any resource in the `kube-system` namespace (cloud provider credentials, platform-critical components) — no `oc` or `kubectl` command may target it. Filter `kube-system` out of all-namespace output (e.g. `oc get pods -A`) before analysis
- Do not call external APIs (Jira, GitHub API, Slack, etc.); the wrapper script handles integrations after the agent exits
- This step runs `best_effort: true` — always exit 0 even if analysis is incomplete
