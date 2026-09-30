---
name: otel-ui
description: Use this skill to analyze failing CI tests of the OpenTelemetry Collector dashboard in the OpenShift web console (Playwright specs started by a chainsaw test, junit_console_ui_otel_* prefix) - rerun the failing specs, check the dashboard queries, diagnose product bug vs test issue vs job configuration, fix test files when needed, and export results. Trigger when $SHARED_DIR/qe-agent-context.json has has_test_failures=true for the OpenTelemetry console UI tests, or when an engineer asks to debug or fix them.
---

# OpenTelemetry Console UI QE Agent — Test Failure Triage and Fix

This skill triages failures of the test that verifies the "OpenTelemetry Collector" dashboard (Observe > Dashboards) published by the OpenTelemetry operator. The agent image is `playwright-base`, with Node.js, Chromium, chainsaw and `oc`, so the skill reruns the whole test and the failing specs here, and checks the dashboard's own queries against the monitoring stack.

## Test Infrastructure Overview

| JUnit prefix | Suite | Framework | Repo |
|---|---|---|---|
| `junit_console_ui_otel_dashboard*` | Dashboard specs: `<testsuite name="collector-dashboard.spec.ts">`, cases `OpenTelemetry Collector dashboard › <title>` | Playwright | `https://github.com/openshift/distributed-tracing-qe` (`tests/e2e-otel-ui/collector-dashboard/ui`) |
| `junit_console_ui_otel_chainsaw*` | Wrapper, test case `collector-dashboard`: user workload monitoring, collectors, telemetrygen Jobs, `check_metrics.sh`, then Playwright | chainsaw | same repo, `tests/e2e-otel-ui/collector-dashboard` |

The files arrive as `qe-agent-junit-<N>.xml`: tell them apart by the `<testsuite name>`, not the file name.

---

## Step 0 — Read Setup Context and Fetch the Step Script

Read `${SHARED_DIR}/qe-agent-context.json`, written by the test step at exit:

```json
{
  "step_script_ref": "distributed-tracing/tests/opentelemetry-ui/upstream/distributed-tracing-tests-opentelemetry-ui-upstream-commands.sh",
  "has_test_failures": true,
  "env": {}
}
```

- `step_script_ref` — path relative to `ci-operator/step-registry/`

Fetch `https://raw.githubusercontent.com/openshift/release/main/ci-operator/step-registry/<step_script_ref>`. Before `chainsaw test` is **setup** (proxy file, console URL, kubeadmin password file, `git clone`); the `chainsaw test` command is the **test execution**.

## Step 0a — Verify Cluster Stability

Mandatory, before Step 0b. Read `/tmp/qe-agent-modules/cluster-stability.md` and follow it. If missing: poll `oc get machineconfigpools.machineconfiguration.openshift.io` every 60s for up to 20 minutes until every pool is `UPDATED=True`, `UPDATING=False`, `DEGRADED=False`; if pools are listed but never become ready, classify `CLUSTER_INSTABILITY` (Step 5d) and skip to Step 6; if the query itself keeps failing, record the MCP status as unavailable, recommend a rerun and skip to Step 6.

## Step 0b — Re-establish the Test Environment

Clone the tests, this is the repo root: `git clone --depth 1 --branch main https://github.com/openshift/distributed-tracing-qe.git /tmp/distributed-tracing-qe` (the step takes the tests from the main branch). The environment of the script (proxy file, console URL, kubeadmin password file, `CI=true`) is set up in Step 3. Verify the operator is installed and `Succeeded` (`oc get csv -n opentelemetry-operator-system`); do not reinstall it. If `qe-agent-context.json` is missing, infer the suite from the JUnit prefix, skip the rerun, and diagnose from the JUnit content and cluster state.

## Step 1 — Parse JUnit XMLs and Identify Failures

Mandatory. Read `/tmp/qe-agent-modules/junit-triage.md` and follow it. Suite rules:
- The specs run serially: the first `<failure>` is the root cause, the `skipped` cases after it did not run. Its text has the assertion, the locator and the call log; the `Error Context:` and `[[ATTACHMENT|…]]` paths (page snapshot, screenshot, trace) are in the test step's artifacts, which this pod cannot read; the reruns of Step 3 write their own.
- The chainsaw XML only says `exit status 1`. Read `${SHARED_DIR}/qe-agent-ui-chainsaw-output.log` (last 100 KiB of Chainsaw's console output): it names the failed step, what it printed and what the catch operations collected (collector status, pod logs, events). No Playwright XML, or one without cases, means the run failed before the specs: in the steps `enable-user-workload-monitoring`, `deploy-collectors`, `generate-telemetry` or `wait-for-dashboard-metrics` (the data pipeline), or in the console login. With no JUnit file at all but this log present, the step failed before any report (a failed clone, a missing password file, the time limit): diagnose from the log, this overrides the module's rule to exit.
- Typical shared root causes: console login failed, dashboard ConfigMap missing, no series in the monitoring stack.

If missing: read `${SHARED_DIR}/qe-agent-junit-*.xml`, extract each suite name and failed `<testcase>` (`<failure>`/`<error>` message and full text), group by suite, and exit with a clear message if there are no files. If more than 5 tests fail, look for one shared root cause and diagnose the simplest failing test as the representative (Steps 2–5); with no pattern, diagnose individually, capped at 3. Write any pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.

---

## Step 2 — Locate Test Source Files

The repo root is the clone from Step 0b. `TEST_DIR=tests/e2e-otel-ui/collector-dashboard`, `TEST_SRC=${TEST_DIR}/ui/specs/collector-dashboard.spec.ts` (one serial `describe`; the case title after `›` locates the test with `grep -n`). Supporting files: `ui/pages/collector-dashboard.page.ts` (`PANELS` with titles and legend templates, selectors), `ui/support/console-login.ts`, `ui/support/env.ts`; fixtures `00-*` (user workload monitoring), `01-otel-collector.yaml` (`cluster-collector` with a `debug` and an always-failing `otlp/unreachable` exporter, plus an idle `second` collector), `02-generate-telemetry.yaml` (Jobs `telemetrygen-traces`, `-metrics`, `-logs`, 15 minutes), `03-*` (RBAC), `check_metrics.sh`. The operator source of the change under test is in `/tmp/opentelemetry-operator` (copied into the agent image; the dashboard is built in `internal/openshift/dashboards/`): read it for the product side of a diagnosis, and reuse it in Step 4a only if it has a `.git` directory.

---

## Step 3 — Rerun the Failing Tests

This pod has the same Node.js, Chromium, chainsaw and `oc` as the test step, so the specs run here. Each bash call is a fresh shell: write the environment once and source it in every block.

```bash
cat > /tmp/otel-ui-env.sh <<'EOF'
[[ -f "${SHARED_DIR}/proxy-conf.sh" ]] && source "${SHARED_DIR}/proxy-conf.sh"
export KUBEADMIN_PASSWORD_FILE="${KUBEADMIN_PASSWORD_FILE:-${SHARED_DIR}/kubeadmin-password}"  # the tests read it, never print it
export BASE_URL="https://$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
export CI=true NO_COLOR=1
unset NAMESPACE
EOF
```

**Run 1: the whole test** (about 9 minutes; use `run_in_background` and poll, the Bash tool stops at 10 minutes). It deploys the collectors and the telemetry, waits for the series, runs the specs, and with `--skip-delete` keeps the test namespace for the next runs:

```bash
source /tmp/otel-ui-env.sh; RUN_DIR="${ARTIFACT_DIR}/otel-ui-rerun1"; mkdir -p "${RUN_DIR}"
for ns in $(oc get namespaces --no-headers -o custom-columns=:metadata.name | grep '^chainsaw-'); do
  oc delete namespace "$ns" --ignore-not-found
done
oc delete clusterrole,clusterrolebinding chainsaw-otel-ui-metrics-api --ignore-not-found  # not removed with the namespace
cd /tmp/distributed-tracing-qe && ARTIFACT_DIR="${RUN_DIR}" chainsaw test --config .chainsaw.yaml --skip-delete --quiet \
  --report-name junit_rerun_otel_ui --report-path "${RUN_DIR}" --report-format XML --test-dir tests/e2e-otel-ui/collector-dashboard
```

Read `${RUN_DIR}/junit_console_ui_otel_dashboard.xml` and the Chainsaw output. For a failing spec, `${RUN_DIR}/test-results/*/error-context.md` is the page snapshot at the failure, and the `.png` next to it is the screenshot (open it with the Read tool). The same failure as in the original run goes to Step 4.

**Dashboard queries.** Whether run 1 passed or failed, the namespace is still there (skip this if it failed before the collectors were deployed). Run the dashboard's own queries (variables replaced by "all") against Thanos. Every query must return a series, except the Processor `dropped` queries (never) and the `refused` queries (only after a refusal) where `0` is normal:

```bash
NS=$(oc get opentelemetrycollector -A --field-selector metadata.name=cluster-collector -o jsonpath='{.items[0].metadata.namespace}')
SA="system:serviceaccount:${NS}:qe-agent-thanos"
oc create serviceaccount qe-agent-thanos -n "$NS" && oc adm policy add-cluster-role-to-user cluster-monitoring-view "$SA"
TOKEN=$(oc create token qe-agent-thanos -n "$NS")
HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
oc get configmap opentelemetry-collector -n openshift-config-managed -o json | jq -r '.data["otel.json"]' > /tmp/otel.json
jq -r '[.rows[]?.panels[]?, .panels[]?][] | .targets[]?.expr' /tmp/otel.json | sed -E 's/"\$[a-z ]+"/".+"/g' > /tmp/exprs.txt
while IFS= read -r q; do
  n=$(curl -sk -H "Authorization: Bearer ${TOKEN}" --data-urlencode "query=${q}" "https://${HOST}/api/v1/query" | jq -r '.data.result | length')
  echo "${n} ${q}"
done < /tmp/exprs.txt
oc adm policy remove-cluster-role-from-user cluster-monitoring-view "$SA"; oc delete serviceaccount qe-agent-thanos -n "$NS"
```

**Runs 2–4: the failing spec only**, against the kept namespace (`npm ci` was done by run 1). The telemetry Jobs stop 15 minutes after run 1: delete them and apply `${TEST_DIR}/02-generate-telemetry.yaml` in `NS` again if needed.

```bash
source /tmp/otel-ui-env.sh; RUN=2   # then 3 and 4
NS=$(oc get opentelemetrycollector -A --field-selector metadata.name=cluster-collector -o jsonpath='{.items[0].metadata.namespace}')
cd /tmp/distributed-tracing-qe/tests/e2e-otel-ui/collector-dashboard/ui
OTEL_UI_NAMESPACE="${NS}" OTEL_UI_DATA_TIMEOUT_SECONDS=120 ARTIFACT_DIR="${ARTIFACT_DIR}/otel-ui-rerun${RUN}" \
  npx playwright test -g "<unique part of the failing case title>" --retries=0
```

Record the pass/fail pattern of the four runs (for example `PFPP`). A failure in even 1 of 4 runs still goes through Step 4 first, and is `FLAKY` (Step 5c) only if that finds no other explanation; an incomplete loop is tentative, never `FLAKY`.

---

## Step 4 — Diagnose: Product Bug vs Test Issue

Run the diagnostics first; the logs, the Step 3 query counts and the failure text are the primary evidence. `NS` is the test namespace that run 1 of Step 3 kept.

```bash
oc get pods -n opentelemetry-operator-system
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --tail=150
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --previous --tail=50 2>/dev/null || true
# The dashboard ConfigMap exists only while the operator runs with OPENSHIFT_CREATE_DASHBOARD=true
oc get csv -n opentelemetry-operator-system -o jsonpath='{.items[0].spec.install.spec.deployments[0].spec.template.spec.containers[0].env}' | jq -c '.[] | select(.name=="OPENSHIFT_CREATE_DASHBOARD")'
oc get configmap opentelemetry-collector -n openshift-config-managed -o jsonpath='{.metadata.labels}{"\n"}'
# Console, authentication and the monitoring plugin that draws the dashboard
oc get clusteroperator console authentication monitoring ingress
oc get pods -n openshift-console
oc get pods -n openshift-monitoring -l app.kubernetes.io/component=monitoring-plugin
# Data path in the test namespace (Step 3: NS) and user workload monitoring
oc get opentelemetrycollector,servicemonitor,pods,jobs -n "${NS}"
oc logs -n "${NS}" job/telemetrygen-traces --tail=20 2>/dev/null || true
oc get pods -n openshift-user-workload-monitoring
oc get events -n "${NS}" --sort-by='.lastTimestamp' | tail -20
```

### Failure text → cause

| Signal | Check | Likely classification |
|---|---|---|
| Login: timeout on `#inputUsername` or `[data-test="username"]`; `No kubeadmin password file` | console and authentication operators, console pods, `curl -sk -o /dev/null -w '%{http_code}' https://<console host>/` | login page changed: `TEST_ISSUE`; console or OAuth down: `PRODUCT_BUG`; missing password file: `JOB_CONFIG` |
| `ConfigMap openshift-config-managed/opentelemetry-collector not found` | `OPENSHIFT_CREATE_DASHBOARD` in the CSV, operator restarts, operator logs | flag unset in the bundle: `JOB_CONFIG`; flag set, operator running, ConfigMap missing: `PRODUCT_BUG`; operator restarted meanwhile: see `CLUSTER_INSTABILITY` below |
| ConfigMap label or `title` assertion | the ConfigMap label and `.title` in `otel.json` | intended rename: `TEST_ISSUE`; unintended: `PRODUCT_BUG` |
| Observe, Dashboards, `dashboard-dropdown` or picker option not found | ConfigMap label, `monitoring-plugin` pods, console plugins (`oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'`) | console UI change: `TEST_ISSUE`; plugin not running: `PRODUCT_BUG` |
| row not visible, `toHaveCount(3)` | rows and panels in `otel.json` against the spec | dashboard changed on purpose: `TEST_ISSUE`; broken JSON: `PRODUCT_BUG` |
| `No datapoints found.`, legend missing, `toPass` timeout on a panel; or Chainsaw `Timed out after … waiting for series` | Step 3 query counts | series absent: data path (user workload monitoring pods, ServiceMonitor `*-monitoring-collector`, `enableMetrics`, telemetrygen logs); collector metric names no longer match the dashboard queries (for example a `_total` suffix): `PRODUCT_BUG`. Series present: compare `legendFormat` in `otel.json` with `PANELS`: changed `TEST_ISSUE`, same `PRODUCT_BUG` (console rendering) |
| `metric exporter` dropdown missing `otlp/unreachable` | `otelcol_exporter_send_failed_metric_points` in the counts | the always-failing exporter no longer fails: `TEST_ISSUE` (fixture) |
| collector instance or namespace filter | Service names `<cr>-collector-monitoring` | Service renamed by the operator: `PRODUCT_BUG`, else `TEST_ISSUE` |
| `ImagePullBackOff` of `telemetrygen` or the collector | pod events, registry reachability | `JOB_CONFIG` |

### Known dashboard behaviour (verified on OCP 4.22, operator 0.158)

- **Metrics Exported vs Failed / second** is empty until `otelcol_exporter_send_failed_metric_points` exists (the `metric exporter` variable is built from it, so the console sends `undefined` queries). The fixture avoids it with the failing `otlp/unreachable` exporter. Do not file this again as new unless that series exists and the panel is still empty.
- The `dropped` series of both Processor panels cannot exist (the memory limiter has no dropped metric); `refused` series may be absent (they can be missing until a refusal happens). The specs do not assert them.
- The dashboard is offered only for All Projects, panels render lazily, and a first-time user gets a welcome dialog: the spec handles all three.

### Product Bug indicators
Classify as `PRODUCT_BUG` when the operator, the collector metrics or the console itself misbehaved:
- operator pod `CrashLoopBackOff` or `OOMKilled`; dashboard ConfigMap missing while the flag is set and the operator runs
- collector metric names or labels that the published dashboard queries do not match
- the monitoring plugin or console returns errors, or draws a panel wrongly although the series exist

### Test Issue indicators
Classify as `TEST_ISSUE` when the test is wrong or stale:
- selector, `data-test` id, page text, dashboard title, panel title or legend format that changed on purpose
- fixture names or Service names that changed; assertion on a series that cannot exist

### Cluster Instability indicators

Before `CLUSTER_INSTABILITY`, rule out a tight operator reconciliation loop with debug logging:

```bash
CSV=$(oc get csv -n opentelemetry-operator-system --no-headers \
  | awk '/opentelemetry-operator/ && /Succeeded/{print $1}' | head -1)
IDX=$(oc get csv "$CSV" -n opentelemetry-operator-system \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}' \
  | awk '/--zap-log-level/{print NR-1; exit}')
if [[ -z "$IDX" ]]; then echo "WARNING: --zap-log-level not found in CSV args"; else
  oc patch csv "$CSV" -n opentelemetry-operator-system --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args/${IDX}\",\"value\":\"--zap-log-level=debug\"}]"
  oc rollout status deploy/opentelemetry-operator-controller-manager -n opentelemetry-operator-system --timeout=3m
fi
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --tail=500 \
  | grep -E '"reconcileID"|"Reconciling"|"requeue"|"error"' | head -100
```

Mandatory. Read `/tmp/qe-agent-modules/cluster-instability.md` (loop indicators and the four conditions for `CLUSTER_INSTABILITY`) and follow it. If missing: classify `CLUSTER_INSTABILITY` only when the MCPs were updating (or operator restarts correlate with the rollout) at the original run, the Step 3 rerun passes cleanly and faster, and neither a test defect nor a reconciliation loop explains the failure; a loop is a `PRODUCT_BUG` (Step 5b); otherwise it takes precedence over `FLAKY` (Step 5d).

---

## Step 4a — Attribution

Mandatory. Read `/tmp/qe-agent-modules/attribution.md` and follow it, including its Step 5/6 additions. If missing, write `${ARTIFACT_DIR}/attribution.json` with `"status": "failed"` and continue.

## Step 5a — If TEST_ISSUE: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a test" and "Export the fix". Edit the Playwright TypeScript (`ui/specs`, `ui/pages`, `ui/support`) or the YAML fixtures. Typical fixes: selector or `data-test` id, dashboard or panel title or legend template in `PANELS`, a changed collector or Service name. Verify the fix with `npx tsc --noEmit` in `ui` and the failing spec in the Step 3 loop (the namespace is still there), and write the result as the verification in `CHANGES.md`. If missing: make the minimal change, copy only the changed files to `${ARTIFACT_DIR}/test-fixes/` preserving the repo-relative path, and write `${ARTIFACT_DIR}/test-fixes/CHANGES.md` (banner `> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.`; Failing test, Root cause, Fix applied, Files changed, Verification).

---

## Step 5b — If PRODUCT_BUG: Write Bug Report

Mandatory. Read `/tmp/qe-agent-modules/product-bug-report.md` and follow it. Affected component: OpenTelemetry operator (dashboard ConfigMap `openshift-config-managed/opentelemetry-collector`, collector metrics) or the OpenShift console monitoring plugin, as the evidence shows; namespace `opentelemetry-operator-system` (console: `openshift-console`, `openshift-monitoring`). If missing: write `${ARTIFACT_DIR}/bug-report.md` (AI-Generated Content banner as in Step 5a; Summary, Affected component, Reproduction, Observed behavior, Expected behavior, Evidence, Suggested severity) and `${ARTIFACT_DIR}/jira-payload.json` via `jq -n --arg`: `summary` (`[qe-agent]` prefix, ≤ 255 characters), `description` (the report in Jira wiki notation, starting with `*Severity:* <level>`) and `severity`. Redact credentials, tokens, passwords and SHA-256 digests as `[REDACTED]`.

---

## Step 5c — If FLAKY: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a flaky test" and "Export the fix". If missing: make the minimal change that removes the race (no blanket retries), export as in Step 5a, and describe the timing evidence in `CHANGES.md`. Typical fixes: an `expect(...).toPass()` or web-first assertion on the state the test needs instead of a fixed wait, a longer `OTEL_UI_DATA_TIMEOUT_SECONDS` default only when the first scrape is proven slow.

---

## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Mandatory. Follow "Incident note" in `/tmp/qe-agent-modules/analysis-summary.md`. If missing: write `${ARTIFACT_DIR}/cluster-instability-report.md` with the AI-Generated Content banner, a one-sentence summary, an affected-tests table (suite / test case / original vs rerun duration), the root cause (include the Step 0a MCP snapshot), evidence, and a recommendation to rerun the CI job.

---

## Step 5e — If JOB_CONFIG: Recommend a Job Configuration Change

The test and product are fine, but the job lacks something (the kubeadmin password file, `OPENSHIFT_CREATE_DASHBOARD=true` in the operator bundle, access to the telemetrygen image). Don't modify tests or write `jira-payload.json`. In `qe-agent-analysis.md`, give the evidence and the exact change: the step `distributed-tracing-tests-opentelemetry-ui-upstream` and the job `opentelemetry-ui-tests` (variant `upstream-ui-ocp-4.22-amd64`) are in `ci-operator/config/openshift/open-telemetry-opentelemetry-operator/`.

---

## Step 6 — Write Analysis Summary

Mandatory. Follow "Analysis summary" in `/tmp/qe-agent-modules/analysis-summary.md`. Classifications also include `JOB_CONFIG` (Step 5e). If missing: write `${ARTIFACT_DIR}/qe-agent-analysis.md` with the AI-Generated Content banner immediately after each diagnosis, without overwriting earlier tests' entries. Per test: Failed Tests, Rerun Result, Diagnosis (classification + evidence), Rerun Summary (Original + Reruns 1–4), Outcome, Evidence Sources. Finish with one Skill Improvement Recommendations section (deviations from skill steps, `None.` if none).

---

## Notes for CI context

- The cluster is already provisioned with the OpenTelemetry operator built from the change under test. The `chainsaw-*` namespace of the original run is already gone; run 1 of Step 3 creates a new one and leaves it (`--skip-delete`)
- The qe-agent runs in a fresh pod — `/tmp/` is empty at start; Step 0b clones the tests
- `$KUBECONFIG` points to the test cluster; `oc`, `kubectl`, `chainsaw`, `yq`, `jq`, `curl`, `git`, Node.js, npm and Chromium (`PLAYWRIGHT_BROWSERS_PATH`) are in PATH: do not run `npx playwright install`
- The tests read `KUBEADMIN_PASSWORD_FILE` themselves for the console login: never `cat` or print it, and never put it in a command
- All output goes to `$ARTIFACT_DIR` (GCS) or `$SHARED_DIR`; do not copy large files to `$SHARED_DIR` (1 MiB Secret limit)
- **Namespace restriction**: MUST NOT access, read, list, or modify any `kube-system` resource — an all-namespaces query filtered afterward still fetches it, so scope every command to named namespaces or a label selector (`-A` is only used above with a `--field-selector` on the collector name)
- Do not call external APIs (Jira, GitHub, Slack); the wrapper script handles integrations after exit
- This step runs `best_effort: true` — always exit 0, even incomplete
