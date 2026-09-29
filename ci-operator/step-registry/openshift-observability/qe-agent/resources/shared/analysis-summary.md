# Incident Note and Analysis Summary (Steps 5d and 6)

This is the body of Step 5d and Step 6, shared by every QE agent skill. Each skill's Step 5d and Step 6 point here.

## Incident note (Step 5d, `CLUSTER_INSTABILITY`)

Write `${ARTIFACT_DIR}/cluster-instability-report.md` with: a one-sentence summary; a table of affected tests (suite / test case / original duration / rerun duration); root cause (for example MCP updates, node evictions, resource contention, operator pod restarts or leader election loss, and include the MCP status snapshot from Step 0a); evidence (MCP output, relevant pod events); and a recommendation to rerun the CI job. Begin the report with the banner below.

## Analysis summary (Step 6)

Write `${ARTIFACT_DIR}/qe-agent-analysis.md` immediately after each test is diagnosed — do not wait until the end. Preserve earlier entries when adding later tests: one section per diagnosed test, never overwrite a previous test's entry. Write partial entries for in-progress flakiness runs ("Rerun 1: PASS — confirmation in progress") and overwrite that test's entry when it completes. Put the pattern conclusion from Step 1's high-failure triage, if there is one, near the top.

````markdown
> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.

# QE Agent Analysis

## <suite> / <test case>

### Failed Tests
| Suite | Test Case | JUnit File |
|---|---|---|
| <suite> | <test-case> | <xml-filename> |

### Rerun Result
<still failing / passed on rerun (flaky) / passed cleanly (cluster instability) / not rerun>

### Diagnosis
**<PRODUCT_BUG | TEST_ISSUE | FLAKY | CLUSTER_INSTABILITY>** (plus any extra classification the skill defines, for example `JOB_CONFIG` or `NOT_REPRODUCED`)

<Two to three sentences explaining the reasoning. Reference specific log lines, error messages, framework errors, MCP status, catalog status or test source fields that led to this conclusion.>

### Rerun Summary
| Run | Result |
|---|---|
| Original CI run | FAIL |
| Rerun 1 | PASS / FAIL / N/A |
| Rerun 2 | PASS / FAIL / N/A |
| Rerun 3 | PASS / FAIL / N/A |
| Rerun 4 | PASS / FAIL / N/A |

### Outcome
<If TEST_ISSUE>: Test fix applied. Changed files in `${ARTIFACT_DIR}/test-fixes/`. See `CHANGES.md` for details.
<If PRODUCT_BUG>: Bug report written to `${ARTIFACT_DIR}/bug-report.md`.
<If FLAKY>: Flaky test confirmed (pattern: <e.g. PFPP>). Fix applied to `${ARTIFACT_DIR}/test-fixes/`. See `CHANGES.md` for root cause and fix details.
<If CLUSTER_INSTABILITY>: Incident note written to `${ARTIFACT_DIR}/cluster-instability-report.md`. Recommendation: rerun the CI job.
<If the skill defines JOB_CONFIG>: No test or product change. Recommended job config change: <exact env/config change and file>.
<If the skill defines NOT_REPRODUCED>: All reruns passed, so no code change. Pass/fail pattern as evidence; recommendation: rerun.

### Suspected Introducing Change
<only when the attribution module ran in Step 4a: its table and caveat, see attribution.md>

### Evidence Sources
- JUnit XML: `<filename>` — failure message at line <N>
- Operator logs: `<namespace>/<deployment>` — <relevant log excerpt>
- Cluster state: <MCP status / CRD or catalog availability / pod status>
- Test source: `<file-path>` — <what was found>

## Attribution Improvement Notes
<only when the attribution module ran in Step 4a: mandatory, even when attribution was skipped or failed, see attribution.md>

## Skill Improvement Recommendations
<!-- One document-level section at the end. Record deviations from the skill steps: commands that failed and had to be adapted, decisive diagnostics the skill did not mention, steps that were unnecessary or slow, cleanup that did not work, or assumptions (namespace, resource name, container index) that did not hold. -->
<If the skill steps were followed exactly and worked as written>: None.
<Otherwise, one bullet per finding>:
- **Step <N> — <short title>**: <What the skill said to do> → <What actually worked / what was wrong and why>. Suggested fix: <concrete change to the skill>.
````

The two attribution sections are required whenever Step 4a ran, so keep them even though the skill's own section list does not name them. Omit **Suspected Introducing Change** for a test whose attribution was skipped, and say why in the Attribution Improvement Notes.
