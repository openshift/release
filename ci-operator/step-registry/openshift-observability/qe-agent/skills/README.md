# QE Agent Skills

Skills are Markdown files that define how Claude Code CLI triages and debugs failing tests for a specific operator or component. Each skill is loaded at runtime as Claude's system prompt and drives an autonomous test failure analysis loop.

This document describes the required structure and conventions that every skill must follow. Review the existing skills (`TEMPO.md`, `OTEL.md`, `TRACING_UI.md`, `DISCONNECTED.md`) as reference implementations.

---

## File format

Every skill file must start with YAML frontmatter:

```yaml
---
name: <kebab-case-identifier>
description: <One-sentence description stating what the skill does, which test suite it targets (by JUnit prefix), what framework the tests use, and when to trigger. This is used by Claude to decide when the skill applies.>
---
```

The `name` field is a unique identifier. The `description` field should mention:
- The operator or component name
- The JUnit XML prefix (e.g., `junit_tempo_*`)
- The test framework (chainsaw, Cypress, Ginkgo, etc.)
- The trigger condition (`$SHARED_DIR/qe-agent-context.json` with `has_test_failures=true`)

---

## Required sections

Every skill must include the following sections in order. The step numbering and titles must be preserved exactly — the agent's command script references this structure.

### Test Infrastructure Overview

A table mapping JUnit prefixes to suites, frameworks, and source repos:

```markdown
| JUnit prefix | Suite | Framework | Repo |
|---|---|---|---|
| `junit_<prefix>_*` | <Component Name> | <chainsaw/Cypress/Ginkgo> | `https://github.com/<org>/<repo>` |
```

### Step 0 — Read Setup Context and Fetch the Step Script

Instructions to read `${SHARED_DIR}/qe-agent-context.json`, construct the raw GitHub URL for the step script, and fetch it. Include a sample JSON showing the expected `step_script_ref` and `env` fields for your component.

### Step 0a — Verify Cluster Stability

MachineConfigPool readiness check with a 60-second poll loop and 20-minute timeout. This section is identical across all skills — copy it verbatim from an existing skill.

### Step 0b — Re-establish the Test Environment

Instructions to replay the setup section of the fetched step script. Include an adaptation table mapping script patterns to required changes:

| Script pattern | Adaptation |
|---|---|
| `cp -R /tmp/<name>` (image mount) | Replace with `git clone` |
| `kubectl create -f <url>` | Use `kubectl apply -f` |
| `oc patch csv ...` | Skip if already patched |
| `$SKIP_TESTS` block | Skip entirely |

Add any framework-specific adaptations (e.g., `unset NAMESPACE` for chainsaw, `GOPATH` re-export, `npm install` for Cypress).

### Step 1 — Parse JUnit XMLs and Identify Failures

Instructions to read `${SHARED_DIR}/qe-agent-junit-*.xml`, extract failed test cases, and group by suite. Must include the **high-failure triage** rule: when more than 5 tests fail, look for a common root cause pattern before processing individually. Cap individual processing at 3 tests.

### Step 2 — Locate Test Source Files

Instructions to map JUnit test case names to source directories. Specify the test directory structure for your component (e.g., `tests/e2e-openshift/<name>/` for Tempo, `tests/cypress/e2e/<spec>.cy.js` for Cypress). Use `find -path` not `find -name`.

### Step 3 — Rerun the Failing Tests

Must include:
1. **Cleanup procedure** before each rerun — framework-specific (chainsaw namespace + clusterrole cleanup, or Cypress prerequisite verification)
2. **First rerun command** with `--report-name` writing to `${ARTIFACT_DIR}` and `--report-format XML`
3. **Flakiness confirmation loop** — if the first rerun passes, run 3 more times (4 total) with unique report names and cleanup between each run. Record the pass/fail pattern.

For chainsaw-based skills, always include `--skip-delete` and `unset NAMESPACE`. For Cypress-based skills, include `--browser chrome --headless`.

### Step 4 — Diagnose: Product Bug vs Test Issue

Must include:
1. **Operator diagnostics** — pod status, logs (current + previous), CR status across all namespaces, events, CSV/subscription status
2. **CRD and API availability check**
3. **Product Bug indicators** — list of conditions that indicate an operator/operand defect
4. **Test Issue indicators** — list of conditions that indicate a broken or stale test
5. **Cluster Instability indicators** — reconciliation loop detection via debug logging, with the four-condition rule for classification. `CLUSTER_INSTABILITY` takes precedence over `FLAKY` when all four hold.

### Step 5a — If TEST_ISSUE: Fix and Export

Minimal test fix, copy changed files to `${ARTIFACT_DIR}/test-fixes/` preserving repo-relative paths, write `CHANGES.md` with the required template (Failing test, Root cause, Fix applied, Files changed, Verification).

### Step 5b — If PRODUCT_BUG: Write Bug Report

Write `${ARTIFACT_DIR}/bug-report.md` with the required template (Summary, Affected component, Reproduction, Observed/Expected behavior, Evidence with operator logs + cluster events + JUnit failure, Suggested severity).

### Step 5c — If FLAKY: Fix and Export

Fix the race condition or timing issue. Include framework-specific examples (chainsaw `wait` steps, Cypress `cy.intercept`/`cy.wait`). Copy changed files and write `CHANGES.md` with the pass/fail pattern as evidence.

### Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Write `${ARTIFACT_DIR}/cluster-instability-report.md` with summary, affected tests table, root cause, evidence, and rerun recommendation.

### Step 6 — Write Analysis Summary

Write `${ARTIFACT_DIR}/qe-agent-analysis.md` with these required sections:
- **Failed Tests** — table with Suite, Test Case, JUnit File
- **Rerun Result** — one line
- **Diagnosis** — bold classification + 2-3 sentences citing evidence
- **Rerun Summary** — table with Original CI run + Reruns 1-4
- **Outcome** — per classification
- **Skill Improvement Recommendations** — deviations from skill steps, or `None.`

### Notes for CI context

Must state:
- The cluster is already provisioned and the operator is already installed
- The test repo is set up by Step 0b from the fetched step script
- `$KUBECONFIG` is set; list available CLI tools (oc, kubectl, chainsaw/npx/etc.)
- All output goes to `$ARTIFACT_DIR` or `$SHARED_DIR`
- The step runs `best_effort: true` — always exit 0

---

## Adding a new skill

1. Create `skills/<TEAM_NAME>.md` following this structure
2. Add your team identifier to the `OWNERS` file in `skills/`
3. Open a PR to `openshift/release`
4. Set `AGENT_SKILL: <TEAM_NAME>` in your CI config

Skill names must match `^[A-Za-z0-9_-]+$`. The step rejects any value with other characters.

---

## Conventions

- **Copy the MCP stability check (Step 0a) verbatim** — it is identical across all skills and must not be modified.
- **Operator diagnostics (Step 4) must be specific to your component** — use the correct namespace, deployment name, CR kinds, and CRD patterns for your operator.
- **Chainsaw skills must include `unset NAMESPACE`** before every `chainsaw test` call.
- **Each bash invocation starts a fresh shell** — re-declare variables (`TEST_DIR`, `GOPATH`, etc.) at the top of every bash block.
- **Use `--skip-delete` for chainsaw reruns** so resources remain on-cluster for inspection, but always clean up before the next rerun.
- **Cap analysis at 3 individual tests** when no common pattern is found in high-failure triage.
