---
name: disconnected-qe-agent
description: Use this skill to analyze failing CI tests for the OpenShift Distributed Tracing disconnected suite (distributed-tracing-qe repo), rerun the specific failing tests (chainsaw-based, junit_distributed_tracing_disconnected prefix), diagnose whether the failure is a product bug, mirror/catalog configuration issue, or a test that needs fixing, apply fixes to test source files when needed, and export results to the artifact directory. Trigger whenever $SHARED_DIR/qe-agent-context.json is present with has_test_failures=true for disconnected distributed tracing tests, or when an engineer asks to debug, rerun, or fix failing disconnected QE tests.
---

# Disconnected Distributed Tracing QE Agent — Test Failure Triage and Fix

This skill drives an agentic loop that takes failing CI test results for the disconnected distributed tracing test suite, reruns the failing tests, determines root cause (product bug, image mirror configuration issue, or broken test), and either fixes the test or writes a structured bug report.

In a disconnected cluster, no direct internet access is available — images must be mirrored to an internal registry and catalog sources must reference mirror registries. The most common failure cause in this suite is image pull failures due to missing or misconfigured mirror entries.

## Test Infrastructure Overview

| JUnit prefix | Suite | Framework | Repo |
|---|---|---|---|
| `junit_distributed_tracing_disconnected` | Disconnected (distributed-tracing-qe) | chainsaw | `https://github.com/openshift/distributed-tracing-qe` |

This suite tests both OpenTelemetry and Tempo operators in a cluster with no direct internet access.

---

## Step 0 — Read Setup Context and Fetch the Step Script

Read `${SHARED_DIR}/qe-agent-context.json`. The test step writes it at exit time:

```json
{
  "step_script_ref": "distributed-tracing/tests/disconnected/distributed-tracing-tests-disconnected-commands.sh",
  "has_test_failures": true,
  "env": {
    "MULTISTAGE_PARAM_OVERRIDE_OTEL_INDEX_IMAGE": "brew.registry.redhat.io/rh-osbs/iib:1155560",
    "MULTISTAGE_PARAM_OVERRIDE_TEMPO_INDEX_IMAGE": "brew.registry.redhat.io/rh-osbs/iib:1157120"
  }
}
```

- `step_script_ref` — path relative to `ci-operator/step-registry/` in the openshift/release repo
- `env` — runtime env var values that were injected at job time and are needed to reproduce setup (e.g. IIB index image references); these are critical for disconnected tests — export them before running setup

Construct the raw GitHub URL and fetch the script:

```text
https://raw.githubusercontent.com/openshift/release/main/ci-operator/step-registry/<step_script_ref>
```

Read the script carefully. It is divided into two logical sections:
1. **Setup** — everything before the `chainsaw test` commands: cloning repos, `oc apply`, mirror configuration, catalog source creation, `kubectl create`, env variable setup
2. **Test execution** — the `chainsaw test` invocations themselves

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

Export any env vars from the `env` field (especially `MULTISTAGE_PARAM_OVERRIDE_*` vars — they point to the IIB index images for disconnected catalog sources), then **run the setup section of the fetched script** — the commands up to (but not including) the first `chainsaw test` invocation.

Required adaptations:

| Script pattern | Adaptation |
|---|---|
| `cp -R /tmp/<name>` (image mount) | Replace with `git clone <repo> <dest>` — find the repo URL from `oc get csv -o yaml \| grep github.com` or the CI config |
| `kubectl create -f <url>` (CRDs) | Use `kubectl apply -f <url>` — `create` fails if the CRD exists from the prior run |
| `oc patch csv ...` | Skip — the operator is already patched from the original test run |
| `$SKIP_TESTS` block | Skip entirely — `$SKIP_TESTS` is unset in the qe-agent pod |
| chainsaw test invocation | Run `unset NAMESPACE` before every `chainsaw test` call — a set `NAMESPACE` causes tests to run in the wrong namespace |
| Mirror/IDMS/ITMS setup | The mirror configuration from the original run should already be applied; verify with `oc get idms` and `oc get itms` before re-applying |

After setup, `cd` into the repo directory and proceed with Steps 1–6.

If `qe-agent-context.json` does not exist, infer the suite from the JUnit file name prefix (`junit_distributed_tracing_disconnected` → Disconnected) and skip the rerun — proceed directly to diagnosis from the JUnit content and cluster state.

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

When the total number of failing test cases is more than 5, it is very likely that all failures share a single root cause. In disconnected clusters the most common cause is image pull failures (mirror not configured for a newly added image) rather than independent bugs.

**What to do:**

1. **Look for a common pattern** across the failure messages. Common indicators for disconnected:
   - All messages contain `ImagePullBackOff`, `ErrImagePull`, `Failed to pull image`, or `unauthorized`
   - All tests fail at the same chainsaw step (usually the first `apply` or `assert` step)
   - Pod events show `Failed to pull image "registry.redhat.io/..."` (the non-mirrored registry)

2. **If a clear pattern exists (especially image pull)**: immediately run the disconnected diagnostics in Step 4 — do not rerun tests until the mirror configuration is verified and fixed. Image pull failures will not resolve on rerun until the mirror is corrected.

3. **If no clear pattern**: pick the simplest failing test as the representative case and proceed with Steps 2–5 for that test only, capping at 3 tests if needed.

Write the pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.

---

## Step 2 — Locate Test Source Files

The JUnit test case name usually matches the folder name under the test directory. For example, a failing test named `e2e/disconnected-smoke` corresponds to `tests/e2e/disconnected-smoke/`. Inside that folder look for:
- `chainsaw-test.yaml` — the test definition (steps, assertions)
- `*.yaml` resource manifests applied during the test
- `assert.yaml` / `error.yaml` — explicit assertion files

To find the right folder when the name mapping is unclear, use:
```bash
find <repo-root>/tests -type d -path "*/<test-name>"
```

Use `-path` (not `-name`) — `-path` matches the full directory path so nested test folders are matched; `-name` only matches the final path component and will miss them.

Once located, record this as `TEST_DIR`. The rerun commands in Step 3 reference `${TEST_DIR}` directly.

Use the destination path from the fetched step script as your repo root — do not guess or scan `/tmp/` broadly.

---

## Step 3 — Rerun the Failing Tests

**Important for disconnected clusters**: before rerunning, verify that image pull failures are not the root cause (Step 4 diagnostics). Rerunning a test that fails due to a missing mirror entry will always fail until the mirror configuration is corrected.

### Cleaning up test resources before each rerun

Chainsaw reruns use `--skip-delete` so resources remain on the cluster after the test finishes. Clean up before each rerun:

```bash
# Delete the chainsaw test namespace and wait for it to terminate
kubectl delete namespace chainsaw-<test-name> --ignore-not-found=true
kubectl wait --for=delete namespace/chainsaw-<test-name> --timeout=5m 2>/dev/null || true

# Delete cluster-scoped resources created by this test
kubectl delete clusterrole,clusterrolebinding \
  -l app.kubernetes.io/managed-by=chainsaw \
  -l chainsaw.kyverno.io/test-namespace=chainsaw-<test-name> \
  --ignore-not-found=true
# Fallback: -l chainsaw.kyverno.io/test-name=<test-name>

# Verify cleanup
kubectl get namespace | grep "chainsaw-<test-name>" && echo "WARNING: namespace still exists" || echo "Clean"
```

### Disconnected suite — first rerun

```bash
# Declare TEST_DIR explicitly — each bash invocation starts a fresh shell.
TEST_DIR="<value resolved in Step 2>"

unset NAMESPACE
CHAINSAW_CMD="chainsaw test --skip-delete --quiet --report-name junit_rerun_disconnected --report-path ${ARTIFACT_DIR} --report-format XML"
CHAINSAW_CMD+=" --test-dir ${TEST_DIR}"
eval "$CHAINSAW_CMD"
```

After the rerun, read the fresh JUnit XML (saved to `$ARTIFACT_DIR`) to check whether the test is:
- **Consistently failing** — same failure, same message → proceed to Step 4 (diagnose)
- **Passed on first rerun** — possible flakiness → run the test 3 more times (4 total reruns) to confirm
- **Fixed by environment reset** — only relevant if catalog sources or operator state were stale

### Flakiness confirmation loop

If the test passes on the first rerun, run it 3 more times sequentially:

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

  unset NAMESPACE
  CHAINSAW_CMD="chainsaw test --skip-delete --quiet --report-name junit_rerun_disconnected_run${i} --report-path ${ARTIFACT_DIR} --report-format XML"
  CHAINSAW_CMD+=" --test-dir ${TEST_DIR}"
  eval "$CHAINSAW_CMD"
done
```

After all 4 runs, count how many passed vs failed. Record the pass/fail pattern (e.g., `PFPP`, `PPFP`). Then inspect the test source:
- Look for missing `wait` blocks between an action and an assertion
- Look for very short `timeout` values in chainsaw steps (image pulls in disconnected clusters take longer than in connected clusters)
- Look for assertions that depend on ordering of concurrent resources

If the failure is reproducible even 1 out of 4 runs, classify as `FLAKY` and proceed to Step 5c to fix it.

---

## Step 4 — Diagnose: Product Bug vs Test Issue

Read the failure message, rerun output, and test source files together. Then run the full disconnected diagnostics below before making any classification decision — in disconnected clusters, image pull failures are the most common failure cause and must be ruled out first.

### Disconnected Cluster Diagnostics

```bash
# Check both operator namespaces
oc get pods -n opentelemetry-operator-system
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --tail=100
oc get pods -n openshift-tempo-operator
oc logs -n openshift-tempo-operator deploy/tempo-operator-controller --tail=100

# Image pull failures (most common disconnected failure cause)
oc get pods --all-namespaces | grep -E 'ImagePullBackOff|ErrImagePull' 2>/dev/null || true

# Mirror configuration (must be present and correct in disconnected clusters)
oc get idms 2>/dev/null || true       # ImageDigestMirrorSet (OCP 4.13+)
oc get itms 2>/dev/null || true       # ImageTagMirrorSet
oc get imagecontentsourcepolicies 2>/dev/null || true  # OCP 4.12 and earlier

# Catalog sources (must be in READY state in disconnected clusters)
oc get catalogsource -n openshift-marketplace -o wide 2>/dev/null || true

# Events across all test namespaces (image pull errors, operator errors, failed pulls)
oc get events --all-namespaces --sort-by='.lastTimestamp' | grep -E 'Failed|Error|Warning' | tail -30

# CRD availability
oc get crd | grep -E 'opentelemetry|tempo|observability'
```

### Product Bug indicators
Classify as `PRODUCT_BUG` when the evidence shows the operator itself misbehaved in the disconnected environment:
- Operator pod in `CrashLoopBackOff` or `OOMKilled` (not caused by image pull failure)
- Operand resource stuck in an error state with operator logs showing a code defect (not a network error)
- Operator attempts to pull from the public registry despite mirror configuration being correct
- CRD validation error rejecting a valid CR that worked in a prior release

Note: image pull failures where the mirror is *missing* the required image are typically a **PRODUCT_BUG** in the mirror configuration process (the IIB build did not include the required image) or a **TEST_ISSUE** if the test was recently updated to use a new image that hasn't been mirrored yet. Distinguish by checking whether the IDMS/ITMS entries exist for the failing image's registry.

### Test Issue indicators
Classify as `TEST_ISSUE` when the test itself is wrong or stale:
- Hardcoded version string or image tag in the test YAML that doesn't match the currently installed operator version
- Test references an image that has not been added to the mirror configuration (test was updated but mirror list was not)
- Wrong namespace name in an assertion (namespace changed between releases)
- `timeout` values that were set for connected cluster speeds — disconnected image pulls take significantly longer; increase `timeout` accordingly
- Missing prerequisite in the test setup

### Cluster Instability indicators

Before classifying as `CLUSTER_INSTABILITY`, rule out tight operator reconciliation loops. Enable debug logging on both operators:

```bash
# OpenTelemetry Operator
CSV_OTel=$(oc get csv -n opentelemetry-operator-system --no-headers \
  | awk '/opentelemetry-operator/ && /Succeeded/{print $1}' | head -1)
IDX_OTel=$(oc get csv "$CSV_OTel" -n opentelemetry-operator-system \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}' \
  | awk '/--zap-log-level/{print NR-1; exit}')
[[ -n "$IDX_OTel" ]] && oc patch csv "$CSV_OTel" -n opentelemetry-operator-system --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args/${IDX_OTel}\",\"value\":\"--zap-log-level=debug\"}]"

# Tempo Operator
CSV_Tempo=$(oc get csv -n openshift-tempo-operator --no-headers \
  | awk '/tempo-operator/ && /Succeeded/{print $1}' | head -1)
IDX_Tempo=$(oc get csv "$CSV_Tempo" -n openshift-tempo-operator \
  -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].args[*]}{.}{"\n"}{end}' \
  | awk '/--zap-log-level/{print NR-1; exit}')
[[ -n "$IDX_Tempo" ]] && oc patch csv "$CSV_Tempo" -n openshift-tempo-operator --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args/${IDX_Tempo}\",\"value\":\"--zap-log-level=debug\"}]"

oc rollout status deploy/opentelemetry-operator-controller-manager -n opentelemetry-operator-system --timeout=3m 2>/dev/null || true
oc rollout status deploy/tempo-operator-controller -n openshift-tempo-operator --timeout=3m 2>/dev/null || true
oc logs -n opentelemetry-operator-system deploy/opentelemetry-operator-controller-manager --tail=200 \
  | grep -E '"reconcileID"|"Reconciling"|"requeue"|"error"' | head -50
oc logs -n openshift-tempo-operator deploy/tempo-operator-controller --tail=200 \
  | grep -E '"reconcileID"|"Reconciling"|"requeue"|"error"' | head -50
```

A reconciliation loop (same CR reconciled >1/2s, rapid sub-second `requeue` entries) reclassifies to `PRODUCT_BUG`. Classify as `CLUSTER_INSTABILITY` only when **all four** hold: (1) MCPs were updating or an operator pod shows `RESTARTS > 0` correlated with MCP rollout at original run time; (2) tests pass cleanly on all 4 reruns with no image pull failures; (3) no fixable test defect and no mirror configuration gap; (4) no tight reconciliation loop confirmed above. `CLUSTER_INSTABILITY` takes precedence over `FLAKY` when all four hold. Proceed to Step 5d.

When genuinely ambiguous, gather more cluster evidence before deciding. Explain your reasoning explicitly in the output.

---

## Step 5a — If TEST_ISSUE: Fix and Export

Apply the **minimal** change to make the test correct. Avoid refactoring or improving unrelated parts of the test — a focused, small diff is easier to review and merge.

Edit `chainsaw-test.yaml`, `assert.yaml`, resource manifests, or other YAML files in the test folder. Common fixes:
- Update image/version references to match currently mirrored images
- Increase `timeout` values for disconnected cluster speeds (image pulls take longer)
- Fix namespace or field names that changed between releases

After editing, copy only the changed files to `${ARTIFACT_DIR}/test-fixes/` **preserving the directory path relative to the repo root**:

```bash
# Example: tests/e2e/disconnected-smoke/chainsaw-test.yaml was fixed
dest="${ARTIFACT_DIR}/test-fixes/tests/e2e/disconnected-smoke"
mkdir -p "${dest}"
cp tests/e2e/disconnected-smoke/chainsaw-test.yaml "${dest}/"
```

Write a `${ARTIFACT_DIR}/test-fixes/CHANGES.md` using this structure:

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
- `tests/e2e/<folder>/chainsaw-test.yaml`

## Verification
Rerun result after fix: [PASS / FAIL / not re-verified]
```

---

## Step 5b — If PRODUCT_BUG: Write Bug Report

Do not attempt to fix the operator code. Instead, write `${ARTIFACT_DIR}/bug-report.md`:

````markdown
> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.

# Product Bug Report

## Summary
<one-sentence description of the bug>

## Affected component
- Operator: <OpenTelemetry Operator / Tempo Operator>
- Namespace: <opentelemetry-operator-system | openshift-tempo-operator>
- Failing test: <suite / test case>
- Environment: Disconnected cluster (no direct internet access)

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

### Image pull / mirror status
```text
<oc get idms / oc get itms output, and the failing image name>
```

### Cluster events
```text
<relevant events — especially Failed and ImagePullBackOff events>
```

### JUnit failure message
```text
<failure text from XML>
```

## Suggested severity
<Critical / Major / Minor — based on whether this blocks a release gate>
````

After writing `bug-report.md`, also write `${ARTIFACT_DIR}/jira-payload.json` for automated Jira filing.
Convert the bug report content to **Jira wiki notation** using these rules:

| Markdown | Jira wiki notation |
|---|---|
| `# heading` | `h1. heading` |
| `## heading` | `h2. heading` |
| `### heading` | `h3. heading` |
| `**bold**` | `*bold*` |
| `` `code` `` | `{{code}}` |
| ` ```text ... ``` ` | `{code:title=text}...{code}` |
| `- item` | `* item` |
| `1. item` | `# item` |
| `> quote` | `bq. quote` |

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

Apply the minimal change that eliminates the race or timing condition. Do not suppress flakiness with blanket retries — find and fix the root cause.

For disconnected clusters, flakiness often comes from insufficient `timeout` values — image pulls and operator reconciliation are slower in disconnected environments than in connected ones. If a chainsaw step has `timeout: 30s` but an image pull from the internal mirror takes 45–60 seconds, the test will fail intermittently.

Common fixes:
- Increase `timeout` values in chainsaw steps for image-pull-sensitive steps: `timeout: 30s` → `timeout: 5m`
- Add a `wait` step for pod readiness before asserting resource state
- Reorder steps so storage secrets are created before operator CRs

After editing, copy changed files to `${ARTIFACT_DIR}/test-fixes/` (same structure as Step 5a). Write `CHANGES.md` with the pass/fail pattern from the 4 reruns as evidence.

---

## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Write `${ARTIFACT_DIR}/cluster-instability-report.md` with: a one-sentence summary; a table of affected tests (suite / test case / original duration / rerun duration); root cause (MCP updates, node evictions, operator pod restarts/leader election loss — include the MCP status snapshot from Step 0a); evidence (MCP output, relevant pod events); and a recommendation to rerun the CI job. Begin the report with the following banner: `> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.`

---

## Step 6 — Write Analysis Summary

Write `${ARTIFACT_DIR}/qe-agent-analysis.md` immediately after each test is diagnosed — do not wait until the end. Overwrite it after each subsequent test. Write partial entries for in-progress flakiness runs ("Rerun 1: PASS — confirmation in progress") and overwrite when complete.

The document must include these sections:
- **Failed Tests** — table: suite / test case / JUnit file
- **Rerun Result** — one line (still failing / passed on rerun / cluster instability / not rerun)
- **Diagnosis** — bold classification (`PRODUCT_BUG | TEST_ISSUE | FLAKY | CLUSTER_INSTABILITY`) + 2–3 sentences citing specific log lines, image pull errors, or mirror config gaps
- **Rerun Summary** — table: Original CI run + Reruns 1–4, each row `PASS / FAIL`
- **Outcome** — per-classification: test fix location, bug report location, or rerun recommendation
- **Skill Improvement Recommendations** — deviations from skill steps (wrong commands, missing diagnostics, steps that needed adaptation). Examples: a command had a wrong flag; a diagnostic not in the skill was decisive; a step was unnecessary; the cleanup approach did not work; a namespace or resource name assumption was wrong. Write `None.` if all steps worked as written.
- **Evidence Sources** (JUnit XML filename + failure line, operator logs namespace/deployment + excerpt, cluster state checks including mirror config, test source file path + finding)

Begin the document with: `> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.`

---

## Notes for CI context

- The cluster is already provisioned in disconnected mode and the operators are already installed — do not reinstall them
- The test repo is set up by Step 0b using commands from the fetched step script. The qe-agent runs in a fresh pod so `/tmp/` is always empty at start; Step 0b populates it
- **Mirror configuration**: `oc get idms`, `oc get itms`, `oc get imagecontentsourcepolicies` show the current mirror entries — these are cluster-level resources that persist between steps
- `$KUBECONFIG` is set and points to the test cluster; `oc`, `kubectl`, and `chainsaw` are available in PATH
- All output files must go to `$ARTIFACT_DIR` (uploaded to GCS by the sidecar) or `$SHARED_DIR` (accessible to other steps)
- **Namespace restriction**: You MUST NOT access, read, list, or modify any resources in the `kube-system` namespace. This namespace contains cloud provider credentials and platform-critical components. Do not run `oc get`, `oc describe`, `oc logs`, `kubectl`, or any other command that targets `kube-system`. If a diagnostic command defaults to all namespaces (e.g., `oc get pods -A`), filter out `kube-system` from the output before analysis
- This step runs `best_effort: true` — always exit 0 even if analysis is incomplete
