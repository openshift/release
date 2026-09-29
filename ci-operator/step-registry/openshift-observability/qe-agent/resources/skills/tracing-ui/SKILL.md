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

- `step_script_ref` — path relative to `ci-operator/step-registry/`
- `env` — job-time env values needed to reproduce setup; `CYPRESS_SKIP_TESTS` is the job's `@cypress/grep` pattern (empty = all tests), applied to reruns in Step 3

Fetch `https://raw.githubusercontent.com/openshift/release/main/ci-operator/step-registry/<step_script_ref>`. Everything before the first `npx cypress run` / `npm run` is **setup** (clone, IDP/htpasswd, env vars, `npm install`); the rest is **test execution**.

## Step 0a — Verify Cluster Stability

Mandatory, before Step 0b. Read `/tmp/qe-agent-modules/cluster-stability.md` and follow it. If missing: poll `oc get machineconfigpools.machineconfiguration.openshift.io` every 60s for up to 20 minutes until every pool is `UPDATED=True`, `UPDATING=False`, `DEGRADED=False`; if pools are listed but never become ready, classify `CLUSTER_INSTABILITY` (Step 5d) and skip to Step 6; if the query itself keeps failing, record the MCP status as unavailable, recommend a rerun and skip to Step 6.

## Step 0b — Re-establish the Test Environment

Export the `env` vars, then run the script's setup section (up to the first `npx cypress run`) with these adaptations:

| Script pattern | Adaptation |
|---|---|
| `cp -R /tmp/<name>` (image mount) | `git clone --branch main --single-branch <repo> <dest>` — URL/branch from the step script |
| `kubectl create -f <url>` (CRDs) | `kubectl apply -f <url>` — `create` fails if it exists |
| `oc patch csv ...` | Skip — already patched; verify with `oc get csv -n openshift-cluster-observability-operator` |
| `CYPRESS_SKIP_TESTS` block | Keep it; reruns use it (Step 3) |
| htpasswd / oauth setup | Create `uiauto-htpass-secret` only if `oc get secret uiauto-htpass-secret -n openshift-config` fails; patch oauth only if `uiauto-htpasswd-idp` is missing |
| Operator installs / OperatorGroups | Verify readiness, not just presence — require CSV phase `Succeeded`; (re)install if missing or not Succeeded (`after()` can delete or fail COO/OTel/Tempo/Lightspeed). Check `oc get operatorgroup -n <ns>` first; a second one fails the CSV |
| Cypress binary | `npx cypress version` can pass while the binary is only under `/root/.cache/Cypress/`, not `$CYPRESS_CACHE_FOLDER`. If empty: `cp -r /root/.cache/Cypress/*/ /tmp/Cypress/` |

Then continue with Steps 1–6 in the cloned repo. If `qe-agent-context.json` is missing, infer the suite from the JUnit prefix, skip the rerun, and diagnose from the JUnit content and cluster state.

## Step 1 — Parse JUnit XMLs and Identify Failures

Mandatory. Read `/tmp/qe-agent-modules/junit-triage.md` and follow it. Typical shared root causes here: plugin not loaded, auth failure, UI not responding, network error, a failed `before` hook. Pattern signals: the same error string (`Cannot read properties of null`, `401 Unauthorized`) or the same failing Cypress command (`cy.visit`, `cy.get`). If missing: read `${SHARED_DIR}/qe-agent-junit-*.xml`, extract each suite name and failed `<testcase>` (`<failure>`/`<error>` message and full text), group by suite, and exit with a clear message if there are no files. If more than 5 tests fail, look for one shared root cause and diagnose the simplest failing test as the representative (Steps 2–5); with no pattern, diagnose individually, capped at 3. Write any pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.

---

## Step 2 — Locate Test Source Files

The repo root is the clone destination — do not scan `/tmp/` broadly. All tests are in one spec, `tests/e2e/dt-plugin-tests.cy.ts`: a single `describe` whose `before` hook installs/verifies the operators, sets up Lightspeed and creates the UIPlugin, then one `it` per capability. A `before` hook failure skips every test. Locate the `it` block with `grep -n "<test-name>"`. Supporting files under `tests/`: Cypress config, `cypress/support/` custom commands (e.g. `cy.runChainsawTest`), `views/` page objects, `fixtures/` chainsaw tests.

---

## Step 3 — Rerun the Failing Tests

Rerun only the failing test, selected by title with `@cypress/grep`. Each run first executes the whole `before` hook (several minutes, 15+ when installing operators), longer than the Bash tool's 10-minute timeout — use `run_in_background` and poll.

Before rerunning, inspect the RBAC test's `chainsaw-*` namespaces and `verify-traces-*` job pod logs if it failed (chainsaw runs with `--skip-delete`; the `before` hook removes them on the next run), and confirm the console plugin (Step 4 commands) and htpasswd IDP (`oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'`) are still in place.

```bash
cd "<repo root>/tests"
export NO_COLOR=1 CYPRESS_CACHE_FOLDER=/tmp/Cypress CYPRESS_SKIP_COO_INSTALL=true
# Fresh shell — these don't persist, set them in every rerun command:
export CYPRESS_KUBECONFIG_PATH="${KUBECONFIG}"
export CYPRESS_BASE_URL="https://$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
export CYPRESS_LOGIN_IDP="kube:admin"
export CYPRESS_LOGIN_USERS="kubeadmin:$(cat /tmp/secret/kubeadmin-password)"
CYPRESS_SKIP_TESTS=$(jq -r '.env.CYPRESS_SKIP_TESTS // ""' "${SHARED_DIR}/qe-agent-context.json" 2>/dev/null)
GREP="<unique part of the failing test title>"
[[ -n "${CYPRESS_SKIP_TESTS}" ]] && GREP="${GREP}; ${CYPRESS_SKIP_TESTS}"
RUN=1
npx cypress run --browser chrome --headless --spec "e2e/dt-plugin-tests.cy.ts" \
  --env grep="${GREP}",grepOmitFiltered=true \
  --reporter junit --reporter-options "mochaFile=${ARTIFACT_DIR}/junit_rerun_cypress_run${RUN}.xml"
```

### Selecting what to rerun

- Keep `CYPRESS_SKIP_TESTS` in the grep (`;` separates, `-` excludes): the `before` hook reads it too, e.g. `-Lightspeed` skips the Lightspeed install where it's not published.
- Tests are order-dependent: `Capability:RBAC` creates the Tempo instances (`chainsaw-rbac / simplst`, `chainsaw-mmo-rbac / mmo-rbac`) and traces every later test uses except `Capability:TLSCertRotation`/`Capability:Installation`. Include it for others (`GREP="Capability:RBAC; Capability:TraceLimits"`), otherwise the rerun fails on `input[placeholder="Select a Tempo instance"]`.
- For a `before` hook failure, set `GREP` to just `CYPRESS_SKIP_TESTS` (empty runs every test).
- `CYPRESS_SKIP_COO_INSTALL=true` skips the OperatorHub install path (`CYPRESS_COO_UI_INSTALL`, the job default). A passing rerun doesn't verify an install-path fix — mark it "not re-verified" in `CHANGES.md`.

Read the rerun JUnit XML:
- **Same failure** → Step 4
- **Passed** → possible flakiness; confirm with the loop below
- **Fixed by environment reset** — only if the console plugin or auth state was stale

### Flakiness confirmation loop

Run the rerun block 3 more times with `RUN=2`, `3` and `4` (one JUnit file each) and record the pass/fail pattern (e.g. `PFPP`). Look for missing `cy.intercept()` or condition-based waits before asserting UI state, `cy.get()` without a visibility wait, or a changed URL path. A failure in even 1 of 4 runs still goes through Step 4 first — call it `FLAKY` → Step 5c only if that finds no other explanation. An incomplete loop is tentative, never `FLAKY`.

---

## Step 4 — Diagnose: Product Bug vs Test Issue

Run the diagnostics below first; logs and resource status are the primary evidence alongside the failure message and test source.

### Cluster Observability Operator Diagnostics

```bash
# Auto-detect COO namespace
COO_NS="$(oc get pods --all-namespaces -l app.kubernetes.io/name=observability-operator -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
COO_NS="${COO_NS:-openshift-cluster-observability-operator}"

# Operator pod status and logs
oc get pods -n "${COO_NS}"
oc logs -n "${COO_NS}" deploy/observability-operator --tail=150 2>/dev/null || true
oc logs -n "${COO_NS}" deploy/observability-operator --previous --tail=50 2>/dev/null || true

# UIPlugins and MonitoringStacks
oc get uiplugins -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.conditions[*].type}={.status.conditions[*].status} {.status.conditions[*].message}{"\n"}{end}' 2>/dev/null || true
oc get monitoringstacks --all-namespaces -o wide 2>/dev/null || true

# Console plugin registration status
oc get consoleplugin distributed-tracing-console-plugin -o jsonpath='{.status}{"\n"}' 2>/dev/null || true
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}' 2>/dev/null || true

# Events and CSV status
oc get events -n "${COO_NS}" --sort-by='.lastTimestamp' | tail -20
oc get csv -n "${COO_NS}" -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase} — {.status.message}{"\n"}{end}'
```

### CRD and API availability check

```bash
# Missing CRDs cause registration failures
oc get crd | grep -E 'observability|uiplugin|monitoringstack'
oc api-resources | grep observability
```

### Operator catalog availability check

The `before` hook installs COO, OpenTelemetry, Tempo and Lightspeed from `redhat-operators`. Pre-GA OCP versions may lack one, so OperatorHub never renders the install form (`[data-test="install-operator"]` times out). Check before blaming the test or product:

```bash
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
for pkg in cluster-observability-operator opentelemetry-product tempo-product lightspeed-operator; do
  echo "${pkg}: $(oc get packagemanifest "${pkg}" -n openshift-marketplace -o jsonpath='{.status.catalogSource}' 2>/dev/null || echo MISSING)"
done
```

A package missing from the catalog on a pre-GA OCP version is `JOB_CONFIG` (Step 5e): do not add catalog auto-detection or skip logic to the test (it would silently skip the capability where the operator must exist), and do not file a product bug.

### Suppressed exception check

`e2e.js`'s `uncaught:exception` handler swallows crashes like `'Cannot read prop'` — they surface as a timeout, invisible to `qe-agent-commands.log`/JUnit. Before `FLAKY`/`TEST_ISSUE`, re-run with the filter commented out, or diff the API response against what the frontend expects.

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

Before `CLUSTER_INSTABILITY`, rule out a tight COO reconciliation loop with debug logging:

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

Mandatory. Read `/tmp/qe-agent-modules/cluster-instability.md` (loop indicators and the four conditions for `CLUSTER_INSTABILITY`) and follow it. If missing: classify `CLUSTER_INSTABILITY` only when the MCPs were updating (or operator restarts correlate with the rollout) at the original run, all reruns pass cleanly and faster, and neither a test defect nor a reconciliation loop explains the failure; a loop is a `PRODUCT_BUG` (Step 5b); otherwise it takes precedence over `FLAKY` (Step 5d).

---

## Step 4a — Attribution

Mandatory. Read `/tmp/qe-agent-modules/attribution.md` and follow it, including its Step 5/6 additions. If missing, write `${ARTIFACT_DIR}/attribution.json` with `"status": "failed"` and continue.

## Step 5a — If TEST_ISSUE: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a test" and "Export the fix". Typical fixes: selector, route, wait for an async operation, hardcoded name. The tests use Cypress 15: `cy.exec()` yields `{ exitCode, stdout, stderr }` (no `code` field). If missing: make the minimal change, copy only the changed files to `${ARTIFACT_DIR}/test-fixes/` preserving the repo-relative path, and write `${ARTIFACT_DIR}/test-fixes/CHANGES.md` (banner `> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.`; Failing test, Root cause, Fix applied, Files changed, Verification).

---

## Step 5b — If PRODUCT_BUG: Write Bug Report

Mandatory. Read `/tmp/qe-agent-modules/product-bug-report.md` and follow it. Affected component: Cluster Observability Operator / Distributed Tracing Console Plugin, namespace: the COO namespace. If missing: write `${ARTIFACT_DIR}/bug-report.md` (AI-Generated Content banner as in Step 5a; Summary, Affected component, Reproduction, Observed behavior, Expected behavior, Evidence, Suggested severity) and `${ARTIFACT_DIR}/jira-payload.json` via `jq -n --arg`: `summary` (`[qe-agent]` prefix, ≤ 255 characters), `description` (the report in Jira wiki notation, starting with `*Severity:* <level>`) and `severity`. Redact credentials, tokens, passwords and SHA-256 digests as `[REDACTED]`.

---

## Step 5c — If FLAKY: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a flaky test" and "Export the fix". If missing: make the minimal change that removes the race (no blanket retries), export as in Step 5a, and put the pass/fail pattern from the 4 reruns in `CHANGES.md`. Typical fixes: `cy.intercept()` + `cy.wait('@alias')` before asserting post-API UI state, `.should('be.visible')` with a timeout, condition-based waits instead of `cy.wait(<ms>)`.

---

## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Mandatory. Follow "Incident note" in `/tmp/qe-agent-modules/analysis-summary.md`. If missing: write `${ARTIFACT_DIR}/cluster-instability-report.md` with the AI-Generated Content banner, a one-sentence summary, an affected-tests table (suite / test case / original vs rerun duration), the root cause (include the Step 0a MCP snapshot), evidence, and a recommendation to rerun the CI job.

---

## Step 5e — If JOB_CONFIG: Recommend a Job Configuration Change

The test and product are fine, but the job needs something the cluster can't provide (typically an operator unpublished for this OCP version). Don't modify tests or write `jira-payload.json`. In `qe-agent-analysis.md`, give the missing package, OCP version and catalog evidence, and recommend the config change. For Lightspeed, add `CYPRESS_SKIP_TESTS: -Lightspeed` to the e2e `env` in `ci-operator/config/openshift/distributed-tracing-console-plugin/<variant>.yaml`. If COO, OpenTelemetry or Tempo is missing, recommend disabling or re-pointing the job.

---

## Step 6 — Write Analysis Summary

Mandatory. Follow "Analysis summary" in `/tmp/qe-agent-modules/analysis-summary.md`. Classifications also include `JOB_CONFIG` (Step 5e). If missing: write `${ARTIFACT_DIR}/qe-agent-analysis.md` with the AI-Generated Content banner immediately after each diagnosis, without overwriting earlier tests' entries. Per test: Failed Tests, Rerun Result, Diagnosis (classification + evidence), Rerun Summary (Original + Reruns 1–4), Outcome, Evidence Sources. Finish with one Skill Improvement Recommendations section (deviations from skill steps, `None.` if none).

---

## Notes for CI context

- The cluster is already provisioned with COO and the Tracing UI console plugin installed — do not reinstall them
- The qe-agent runs in a fresh pod — `/tmp/` is empty at start; Step 0b clones the test repo there
- `$KUBECONFIG` points to the test cluster; `oc`, `kubectl`, `jq`, `npm`/`npx` are in PATH
- Do **not** copy screenshots/videos to `$SHARED_DIR` (1 MiB Secret limit); only JUnit XML is safe there. Write output to `$ARTIFACT_DIR` (GCS) or `$SHARED_DIR` (shared with other steps)
- **Namespace restriction**: MUST NOT access, read, list, or modify any `kube-system` resource — an all-namespaces query filtered afterward still fetches it, so scope every command to named namespaces or a label selector that excludes it (e.g. `-l app.kubernetes.io/name=...`, as used above), not `-A` piped to `grep -v kube-system`
- Do not call external APIs (Jira, GitHub, Slack); the wrapper script handles integrations after exit
- This step runs `best_effort: true` — always exit 0, even incomplete
