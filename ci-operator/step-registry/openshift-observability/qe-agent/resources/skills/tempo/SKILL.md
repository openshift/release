---
name: tempo
description: Use this skill to analyze failing CI tests for the OpenShift Tempo Operator (TempoStack and TempoMonolithic), rerun the specific failing tests (chainsaw-based, junit_tempo_* prefix), diagnose whether the failure is a product bug or a test that needs fixing, apply fixes to test source files when needed, and export results to the artifact directory. Trigger whenever $SHARED_DIR/qe-agent-context.json is present with has_test_failures=true for Tempo Operator tests, or when an engineer asks to debug, rerun, or fix failing Tempo QE tests.
---

# Tempo Operator QE Agent — Test Failure Triage and Fix

This skill drives an agentic loop that takes failing CI test results for the Tempo Operator, reruns the failing tests, determines root cause (product bug vs broken test), and either fixes the test or writes a structured bug report.

## Test Infrastructure Overview

| JUnit prefix | Suite | Framework | Repo |
|---|---|---|---|
| `junit_tempo_*` | Tempo Operator | chainsaw | `https://github.com/grafana/tempo-operator` |

---

## Step 0 — Read Setup Context and Fetch the Step Script

Read `${SHARED_DIR}/qe-agent-context.json`. The test step writes it at exit time:

```json
{
  "step_script_ref": "distributed-tracing/tests/tempo/upstream/distributed-tracing-tests-tempo-upstream-commands.sh",
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
| `oc patch csv ...` | Skip — the operator is already patched; verify with `oc get csv -n openshift-tempo-operator` |
| `$SKIP_TESTS` block | Skip entirely — `$SKIP_TESTS` is unset in the qe-agent pod |
| `GOPATH=/tmp/go` + `make build` (Tempo stage/downstream only) | Run as part of setup; **re-export `GOPATH`, `GOBIN`, `GOCACHE`, and `PATH` at the start of every bash call in Steps 3–6** — each bash invocation starts a fresh shell and loses the prior environment |
| chainsaw test invocation | Run `unset NAMESPACE` before every `chainsaw test` call — a set `NAMESPACE` causes tests to run in the wrong namespace |

After setup, `cd` into the repo directory and proceed with Steps 1–6.

If `qe-agent-context.json` does not exist, infer the suite from the JUnit file name prefix (`junit_tempo_*` → Tempo) and skip the rerun — proceed directly to diagnosis from the JUnit content and cluster state.

## Step 1 — Parse JUnit XMLs and Identify Failures

Mandatory. Read `/tmp/qe-agent-modules/junit-triage.md` and follow it. Typical shared root causes here: operator crash, missing CRD, network partition, install failure, MinIO/storage not ready. If missing: read `${SHARED_DIR}/qe-agent-junit-*.xml`, extract each suite name and failed `<testcase>` (`<failure>`/`<error>` message and full text), group by suite, and exit with a clear message if there are no files. If more than 5 tests fail, look for one shared root cause and diagnose the simplest failing test as the representative (Steps 2–5); with no pattern, diagnose individually, capped at 3. Write any pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.

---

## Step 2 — Locate Test Source Files

The JUnit test case name usually matches the folder name under the test directory. For example, a failing test named `e2e-openshift/tls-profile` corresponds to `tests/e2e-openshift/tls-profile/`. Inside that folder look for:
- `chainsaw-test.yaml` — the test definition (steps, assertions)
- `*.yaml` resource manifests applied during the test
- `assert.yaml` / `error.yaml` — explicit assertion files

To find the right folder when the name mapping is unclear, use:
```bash
find <repo-root>/tests -type d -path "*/<test-name>"
```

Use `-path` (not `-name`) — `-path` matches the full directory path so nested folders like `e2e-openshift/tls-profile` are matched; `-name` only matches the final path component and will miss them.

Once located, record this as `TEST_DIR` (e.g. `tests/e2e-openshift/tls-profile`). The rerun commands in Step 3 reference `${TEST_DIR}` directly.

Use the destination path from the fetched step script as your repo root — do not guess or scan `/tmp/` broadly.

---

## Step 3 — Rerun the Failing Tests

Rerun only the specific failing tests, not the entire suite, to save time and keep the rerun focused.

### Cleaning up test resources before each rerun

Chainsaw reruns use `--skip-delete` so resources remain on the cluster after the test finishes — this lets you inspect them and understand why a test failed. However, because resources persist, **you must clean up before running the same test again**.

`kubectl delete -f <test-folder>/` is **not sufficient** — chainsaw tests create resources in multiple ways beyond static YAML files: script steps that run `kubectl apply`, resources created by the operator itself (e.g., a `TempoStack` CR triggers the operator to create Deployments, Services, ConfigMaps), cluster-scoped resources (ClusterRoles, ClusterRoleBindings), and chainsaw's own per-test namespaces (prefixed `chainsaw-`).

**Reliable cleanup approach:**

```bash
# 1. Delete the chainsaw test namespace and wait for it to terminate
kubectl delete namespace chainsaw-<test-name> --ignore-not-found=true
kubectl wait --for=delete namespace/chainsaw-<test-name> --timeout=5m 2>/dev/null || true

# 2. Delete cluster-scoped resources created by this test
kubectl get clusterrole,clusterrolebinding -l app.kubernetes.io/managed-by=chainsaw --show-labels 2>/dev/null | head -20
kubectl delete clusterrole,clusterrolebinding \
  -l app.kubernetes.io/managed-by=chainsaw \
  -l chainsaw.kyverno.io/test-namespace=chainsaw-<test-name> \
  --ignore-not-found=true
# Fallback: -l chainsaw.kyverno.io/test-name=<test-name>

# 3. Verify cleanup before rerunning
kubectl get namespace | grep "chainsaw-<test-name>" && echo "WARNING: namespace still exists" || echo "Clean"
```

Read `chainsaw-test.yaml` for the failing test before cleanup — it tells you what namespaces, CRs, and cluster-scoped resources the test creates.

### Tempo Operator — first rerun

Tempo always uses `--config .chainsaw-openshift.yaml` (visible in the fetched step script). Re-export GOPATH for stage and downstream tests so test helpers compiled by `make build` are on PATH.

```bash
# Declare TEST_DIR explicitly — each bash invocation starts a fresh shell.
TEST_DIR="<value resolved in Step 2>"

# Re-export GOPATH for stage/downstream tests (upstream tests don't need this)
export GOPATH=/tmp/go GOBIN=/tmp/go/bin GOCACHE=/tmp/.cache/go-build
export PATH="/tmp/go/bin:${PATH}"

unset NAMESPACE
chainsaw test \
  --skip-delete \
  --config .chainsaw-openshift.yaml \
  --quiet \
  --report-name "junit_rerun_tempo" \
  --report-path "${ARTIFACT_DIR}" \
  --report-format XML \
  --test-dir "${TEST_DIR}"
```

After the rerun, read the fresh JUnit XML. If still failing → proceed to Step 4. If it passed → possible flakiness; run 3 more times (see flakiness loop below).

### Flakiness confirmation loop

If the test passes on the first rerun, run it 3 more times sequentially. Clean up test resources before each run (same namespace + clusterrole delete pattern as above). Use a unique `--report-name` per run so the XMLs don't overwrite each other:

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

  # Re-export GOPATH for stage/downstream so test helpers on /tmp/go/bin are accessible
  export GOPATH=/tmp/go GOBIN=/tmp/go/bin GOCACHE=/tmp/.cache/go-build
  export PATH="/tmp/go/bin:${PATH}"

  unset NAMESPACE
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

After all 4 runs, count how many passed vs failed. Record the pass/fail pattern (e.g., `PFPP`, `PPFP`). Then inspect the test source:
- Look for missing `wait` blocks between an action and an assertion
- Look for very short `timeout` values in chainsaw steps (e.g., `timeout: 30s` where the operator may take longer to reconcile a TempoStack)
- Look for assertions that depend on ordering of concurrent resources

If the failure is reproducible even 1 out of 4 runs, classify as `FLAKY` and proceed to Step 5c to fix it.

---

## Step 4 — Diagnose: Product Bug vs Test Issue

Read the failure message, rerun output, and test source files together. Then run the full operator diagnostics below before making any classification decision — the logs and resource status are the primary evidence.

### Tempo Operator Diagnostics

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

### CRD and API availability check

```bash
# Missing CRDs cause many test failures
oc get crd | grep -E 'tempo|observability'
oc api-resources | grep tempo
```

### Product Bug indicators
Classify as `PRODUCT_BUG` when the evidence shows the operator or operand itself misbehaved:
- Operator pod in `CrashLoopBackOff` or `OOMKilled`
- `TempoStack` or `TempoMonolithic` stuck in an error state not caused by the test YAML
- API object that the operator should have created is missing
- Image pull failure for an operand image referenced in the CSV
- CRD validation error rejecting a valid CR that worked in a prior release
- Timeout waiting for operator reconciliation when the operator logs show no activity
- Storage backend configuration rejected by the operator (object store credentials not mounted, unexpected bucket name format)

### Test Issue indicators
Classify as `TEST_ISSUE` when the test itself is wrong or stale:
- Hardcoded version string or image tag in the test YAML that doesn't match the currently installed operator version
- Wrong namespace name in an assertion (namespace changed between releases)
- Race condition: the test asserts a resource state before the operator has had time to act — look for very short `timeout` values in chainsaw steps or missing `wait` blocks
- Missing prerequisite in the test setup (CRD that must be installed before the test runs but isn't part of the test's `setup` steps)
- Assertion checks a field or value that changed in the operator API (e.g., a renamed status condition on TempoStack)

### Cluster Instability indicators

Before classifying as `CLUSTER_INSTABILITY`, rule out a tight operator reconciliation loop (which causes identical-looking API server pressure). Enable debug logging first:

```bash
CSV_NAME=$(oc get csv -n openshift-tempo-operator --no-headers \
  | awk '/tempo-operator/ && /Succeeded/ {print $1}' | head -1)

# Show current args to confirm --zap-log-level is present
oc get csv "${CSV_NAME}" -n openshift-tempo-operator \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}'

# Find the 0-based index of --zap-log-level and replace its value with debug
ZAP_IDX=$(oc get csv "${CSV_NAME}" -n openshift-tempo-operator \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}' \
  | awk '/--zap-log-level/{print NR-1; exit}')
if [[ -z "${ZAP_IDX}" ]]; then echo "ERROR: --zap-log-level not found in CSV args"; exit 1; fi
oc patch csv "${CSV_NAME}" -n openshift-tempo-operator --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args/${ZAP_IDX}\",\"value\":\"--zap-log-level=debug\"}]"

oc rollout status deploy/tempo-operator-controller -n openshift-tempo-operator --timeout=3m

# Let the operator run 2–3 minutes, then collect debug logs
oc logs -n openshift-tempo-operator deploy/tempo-operator-controller --tail=500 \
  | grep -E '"reconcileID"|"Reconciling"|"requeue"|"error"' \
  | head -100
```

Mandatory. Read `/tmp/qe-agent-modules/cluster-instability.md` (loop indicators and the four conditions for `CLUSTER_INSTABILITY`) and follow it. If missing: classify `CLUSTER_INSTABILITY` only when the MCPs were updating (or operator restarts correlate with the rollout) at the original run, all reruns pass cleanly and faster, and neither a test defect nor a reconciliation loop explains the failure; a loop is a `PRODUCT_BUG` (Step 5b); otherwise it takes precedence over `FLAKY` (Step 5d).

---

## Step 4a — Attribution

Mandatory. Read `/tmp/qe-agent-modules/attribution.md` and follow it, including its Step 5/6 additions. If missing, write `${ARTIFACT_DIR}/attribution.json` with `"status": "failed"` and continue.

## Step 5a — If TEST_ISSUE: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a test" and "Export the fix". Edit `chainsaw-test.yaml`, `assert.yaml`, resource manifests, or other YAML files in the test folder. Common fixes: update image/version references, fix namespace, add a `wait` step before an assertion, correct a changed field name in assertions. If missing: make the minimal change, copy only the changed files to `${ARTIFACT_DIR}/test-fixes/` preserving the repo-relative path, and write `${ARTIFACT_DIR}/test-fixes/CHANGES.md` (banner `> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.`; Failing test, Root cause, Fix applied, Files changed, Verification).

---

## Step 5b — If PRODUCT_BUG: Write Bug Report

Mandatory. Read `/tmp/qe-agent-modules/product-bug-report.md` and follow it. Affected component: Tempo Operator, namespace `openshift-tempo-operator`. If missing: write `${ARTIFACT_DIR}/bug-report.md` (AI-Generated Content banner as in Step 5a; Summary, Affected component, Reproduction, Observed behavior, Expected behavior, Evidence, Suggested severity) and `${ARTIFACT_DIR}/jira-payload.json` via `jq -n --arg`: `summary` (`[qe-agent]` prefix, ≤ 255 characters), `description` (the report in Jira wiki notation, starting with `*Severity:* <level>`) and `severity`. Redact credentials, tokens, passwords and SHA-256 digests as `[REDACTED]`.

---

## Step 5c — If FLAKY: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a flaky test" and "Export the fix". If missing: make the minimal change that removes the race (no blanket retries), export as in Step 5a, and put the pass/fail pattern from the 4 reruns in `CHANGES.md`.

If a step asserts state immediately after a resource is applied, add an explicit `wait` step before the assertion. Example:

```yaml
- name: Wait for TempoStack to be ready before asserting
  wait:
    apiVersion: tempo.grafana.com/v1alpha1
    kind: TempoStack
    name: tempo
    timeout: 5m
    for:
      condition:
        name: Ready
        value: "True"
```

Other common fixes: increase a `timeout: 30s` → `5m` to give the operator time to reconcile a TempoStack (which involves creating many operand Deployments); reorder steps so storage secrets are created before the TempoStack CR.

---

## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Mandatory. Follow "Incident note" in `/tmp/qe-agent-modules/analysis-summary.md`. If missing: write `${ARTIFACT_DIR}/cluster-instability-report.md` with the AI-Generated Content banner, a one-sentence summary, an affected-tests table (suite / test case / original vs rerun duration), the root cause (include the Step 0a MCP snapshot), evidence, and a recommendation to rerun the CI job.

---

## Step 6 — Write Analysis Summary

Mandatory. Follow "Analysis summary" in `/tmp/qe-agent-modules/analysis-summary.md`. If missing: write `${ARTIFACT_DIR}/qe-agent-analysis.md` with the AI-Generated Content banner immediately after each diagnosis, without overwriting earlier tests' entries. Per test: Failed Tests, Rerun Result, Diagnosis (classification + evidence), Rerun Summary (Original + Reruns 1–4), Outcome, Evidence Sources. Finish with one Skill Improvement Recommendations section (deviations from skill steps, `None.` if none).

---

## Notes for CI context

- The cluster is already provisioned and the Tempo operator is already installed — do not reinstall the operator
- The test repo is set up by Step 0b using commands from the fetched step script — the repo path is the destination shown in the script (e.g., `/tmp/tempo-tests`). The qe-agent runs in a fresh pod so `/tmp/` is always empty at start; Step 0b populates it
- **GOPATH**: For Tempo stage and downstream tests, `GOPATH=/tmp/go`, `GOBIN=/tmp/go/bin`, `GOCACHE=/tmp/.cache/go-build` are set and `make build` is run during setup. Because each bash invocation starts a fresh shell, you must re-export `GOPATH`, `GOBIN`, `GOCACHE`, and `PATH` (with `GOBIN` prepended) at the start of any bash call in Steps 3–6 — without `PATH` updated, helper binaries compiled into `/tmp/go/bin` cannot be found by name
- `$KUBECONFIG` is set and points to the test cluster; `oc`, `kubectl`, and `chainsaw` are available in PATH
- All output files must go to `$ARTIFACT_DIR` (uploaded to GCS by the sidecar) or `$SHARED_DIR` (accessible to other steps)
- **Namespace restriction**: You MUST NOT access, read, list, or modify any resources in the `kube-system` namespace. This namespace contains cloud provider credentials and platform-critical components. Do not run `oc get`, `oc describe`, `oc logs`, `kubectl`, or any other command that targets `kube-system`. If a diagnostic command defaults to all namespaces (e.g., `oc get pods -A`), filter out `kube-system` from the output before analysis
- This step runs `best_effort: true` — always exit 0 even if analysis is incomplete
