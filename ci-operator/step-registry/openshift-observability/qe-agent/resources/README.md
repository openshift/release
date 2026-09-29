# QE Agent Skills

Skills are Markdown files that define how Claude Code CLI triages and debugs failing tests for a specific operator or component. Each skill is loaded at runtime as Claude's system prompt and drives an autonomous test failure analysis loop.

This document describes the required structure and conventions that every skill must follow. Review the existing skills (`resources/skills/tempo/SKILL.md`, `otel/SKILL.md`, `tracing-ui/SKILL.md`) as reference implementations.

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

MachineConfigPool readiness check with a 60-second poll loop and 20-minute timeout. The procedure lives in [`shared/cluster-stability.md`](shared/cluster-stability.md) and every skill carries the same pointer (heading `## Step 0a — Verify Cluster Stability`, placed before Step 0b):

```markdown
## Step 0a — Verify Cluster Stability

Mandatory, before Step 0b. Read `/tmp/qe-agent-modules/cluster-stability.md` and follow it. If missing: poll `oc get machineconfigpools.machineconfiguration.openshift.io` every 60s for up to 20 minutes until every pool is `UPDATED=True`, `UPDATING=False`, `DEGRADED=False`; if pools are listed but never become ready, classify `CLUSTER_INSTABILITY` (Step 5d) and skip to Step 6; if the query itself keeps failing, record the MCP status as unavailable, recommend a rerun and skip to Step 6.
```

Do not inline the loop back into a skill; change the shared module instead.

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

JUnit parsing and the **high-failure triage** rule (more than 5 failures: look for a common root cause, diagnose one representative test; otherwise cap individual processing at 3) live in [`shared/junit-triage.md`](shared/junit-triage.md). The skill's Step 1 is a pointer that adds only what is specific to the suite (typical shared root causes, error patterns, test-name conventions):

```markdown
## Step 1 — Parse JUnit XMLs and Identify Failures

Mandatory. Read `/tmp/qe-agent-modules/junit-triage.md` and follow it. Typical shared root causes here: <causes for your suite>. If missing: read `${SHARED_DIR}/qe-agent-junit-*.xml`, extract each suite name and failed `<testcase>` (`<failure>`/`<error>` message and full text), group by suite, and exit with a clear message if there are no files. If more than 5 tests fail, look for one shared root cause and diagnose the simplest failing test as the representative (Steps 2–5); with no pattern, diagnose individually, capped at 3. Write any pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.
```

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
5. **Cluster Instability indicators** — the operator-specific debug-logging commands stay in the skill. The reconciliation-loop indicators and the four-condition rule live in [`shared/cluster-instability.md`](shared/cluster-instability.md); the skill carries this pointer after its commands:

```markdown
Mandatory. Read `/tmp/qe-agent-modules/cluster-instability.md` (loop indicators and the four conditions for `CLUSTER_INSTABILITY`) and follow it. If missing: classify `CLUSTER_INSTABILITY` only when the MCPs were updating (or operator restarts correlate with the rollout) at the original run, all reruns pass cleanly and faster, and neither a test defect nor a reconciliation loop explains the failure; a loop is a `PRODUCT_BUG` (Step 5b); otherwise it takes precedence over `FLAKY` (Step 5d).
```

Routing that differs per suite (for example the `NOT_REPRODUCED` outcome in the logging skills) stays in the skill.

### Step 4a — Attribution

Mandatory, and identical in every skill (heading `## Step 4a — Attribution`, placed between Step 4 and Step 5a):

```markdown
## Step 4a — Attribution

Mandatory. Read `/tmp/qe-agent-modules/attribution.md` and follow it, including its Step 5/6 additions. If missing, write `${ARTIFACT_DIR}/attribution.json` with `"status": "failed"` and continue.
```

The procedure, the per-skill config table and the output requirements live in [`shared/attribution.md`](shared/attribution.md), not in the skill.

### Step 5a — If TEST_ISSUE: Fix and Export

The minimal-fix rule, the export to `${ARTIFACT_DIR}/test-fixes/` (repo-relative paths) and the `CHANGES.md` template live in [`shared/test-fix-export.md`](shared/test-fix-export.md). The skill's pointer adds its framework-specific fixes:

```markdown
## Step 5a — If TEST_ISSUE: Fix and Export

Mandatory. Read `/tmp/qe-agent-modules/test-fix-export.md` and follow "Fix a test" and "Export the fix". <Files to edit and common fixes for your framework.> If missing: make the minimal change, copy only the changed files to `${ARTIFACT_DIR}/test-fixes/` preserving the repo-relative path, and write `${ARTIFACT_DIR}/test-fixes/CHANGES.md` (banner `> **AI-Generated Content** — ...`; Failing test, Root cause, Fix applied, Files changed, Verification).
```


### Step 5b — If PRODUCT_BUG: Write Bug Report

The bug report template, the Jira wiki notation rules, the `jira-payload.json` schema and the redaction rule live in [`shared/product-bug-report.md`](shared/product-bug-report.md). Every skill carries a pointer that supplies its own operator name and namespace for the **Affected component** section:

```markdown
## Step 5b — If PRODUCT_BUG: Write Bug Report

Mandatory. Read `/tmp/qe-agent-modules/product-bug-report.md` and follow it. Affected component: <operator name>, namespace `<namespace>`. If missing: write `${ARTIFACT_DIR}/bug-report.md` (AI-Generated Content banner as in Step 5a; Summary, Affected component, Reproduction, Observed behavior, Expected behavior, Evidence, Suggested severity) and `${ARTIFACT_DIR}/jira-payload.json` via `jq -n --arg`: `summary` (`[qe-agent]` prefix, ≤ 255 characters), `description` (the report in Jira wiki notation, starting with `*Severity:* <level>`) and `severity`. Redact credentials, tokens, passwords and SHA-256 digests as `[REDACTED]`.
```

The wrapper POSTs `jira-payload.json` to Jira (if `JIRA_PROJECT` is configured) and reads only its `summary` and `description` fields. The agent never calls Jira APIs directly.

### Step 5c — If FLAKY: Fix and Export

Fix the race condition or timing issue with the same module: the pointer is `Mandatory. Read /tmp/qe-agent-modules/test-fix-export.md and follow "Fix a flaky test" and "Export the fix". If missing: ...` (see the skills for the full text), followed by your framework-specific examples (chainsaw `wait` steps, Cypress `cy.intercept`/`cy.wait`, Go `wait.PollUntilContextTimeout`). `CHANGES.md` carries the pass/fail pattern as evidence.

### Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

The incident note format lives in [`shared/analysis-summary.md`](shared/analysis-summary.md). The skill's pointer:

```markdown
## Step 5d — If CLUSTER_INSTABILITY: Write Incident Note

Mandatory. Follow "Incident note" in `/tmp/qe-agent-modules/analysis-summary.md`. If missing: write `${ARTIFACT_DIR}/cluster-instability-report.md` with the AI-Generated Content banner, a one-sentence summary, an affected-tests table (suite / test case / original vs rerun duration), the root cause (include the Step 0a MCP snapshot), evidence, and a recommendation to rerun the CI job.
```

### Step 6 — Write Analysis Summary

The `qe-agent-analysis.md` template (one section per diagnosed test, a document-level Skill Improvement Recommendations section, and the attribution sections) lives in the same module. The skill's pointer:

```markdown
## Step 6 — Write Analysis Summary

Mandatory. Follow "Analysis summary" in `/tmp/qe-agent-modules/analysis-summary.md`. If missing: write `${ARTIFACT_DIR}/qe-agent-analysis.md` with the AI-Generated Content banner immediately after each diagnosis, without overwriting earlier tests' entries. Per test: Failed Tests, Rerun Result, Diagnosis (classification + evidence), Rerun Summary (Original + Reruns 1–4), Outcome, Evidence Sources. Finish with one Skill Improvement Recommendations section (deviations from skill steps, `None.` if none).
```

A skill with an extra classification adds one sentence to the pointer (for example `tracing-ui`: "Classifications also include `JOB_CONFIG` (Step 5e)."; the logging skills: "Classifications also include `NOT_REPRODUCED` (Step 4)."). The attribution sections, when Step 4a ran, are listed in the module, so the skill needs no list of its own.

### Notes for CI context

Must state:
- The cluster is already provisioned and the operator is already installed
- The test repo is set up by Step 0b from the fetched step script
- `$KUBECONFIG` is set; list available CLI tools (oc, kubectl, chainsaw/npx/etc.)
- All output goes to `$ARTIFACT_DIR` or `$SHARED_DIR`
- The step runs `best_effort: true` — always exit 0
- The agent must not call external APIs (Jira, GitHub API, Slack, etc.) — external integrations are handled by the wrapper script after the agent exits
- **Namespace restriction**: The agent MUST NOT access, read, list, or modify any resources in the `kube-system` namespace — this namespace contains cloud provider credentials. All skills must include this constraint in their Notes section

---

## Shared modules

Procedures that every skill needs live once under `resources/shared/`, so an improvement made there reaches every team's skill. The wrapper fetches each from `main` and writes it to `/tmp/qe-agent-modules/<name>.md` in the pod, and each skill reads it from a mandatory pointer step:

| Module | Skill step | Purpose |
|---|---|---|
| [`shared/cluster-stability.md`](shared/cluster-stability.md) | Step 0a | MachineConfigPool readiness check (see Step 0a below) |
| [`shared/junit-triage.md`](shared/junit-triage.md) | Step 1 | JUnit parsing and high-failure triage |
| [`shared/cluster-instability.md`](shared/cluster-instability.md) | Step 4 | Reconciliation-loop indicators and the four conditions for `CLUSTER_INSTABILITY` |
| [`shared/attribution.md`](shared/attribution.md) | Step 4a | Git-level attribution, described next |
| [`shared/test-fix-export.md`](shared/test-fix-export.md) | Steps 5a and 5c | Minimal-fix rules, export to `test-fixes/`, `CHANGES.md` template |
| [`shared/product-bug-report.md`](shared/product-bug-report.md) | Step 5b | Bug report template, Jira wiki notation, `jira-payload.json` |
| [`shared/analysis-summary.md`](shared/analysis-summary.md) | Steps 5d and 6 | Incident note and `qe-agent-analysis.md` template |

### Attribution module

`resources/shared/attribution.md` holds the git-level attribution procedure. The wrapper fetches it from `main` and writes it to `/tmp/qe-agent-modules/attribution.md` in the pod; every skill points at that path from a mandatory Step 4a (see [Git-level attribution](../README.md#git-level-attribution)). It adds an attribution pass after Step 4, a **Suspected Introducing Change** section to the Step 5/6 outputs, a mandatory **Attribution Improvement Notes** section, and writes `${ARTIFACT_DIR}/attribution.json`.

Keeping shared procedures in referenced files also keeps `SKILL.md` small, because referenced files do not count toward skillsaw's 6,000-token limit. Put any new shared procedure in a module rather than in the skills. Consequences for skill authors:

- Every skill must include the Step 4a below, placed between Step 4 and Step 5a. The modules refer to the skill's steps by number and title (Step 0a/0b, Step 2 `TEST_DIR`/`TEST_SRC`, Step 4 classification, Step 5a–5d, Step 6), so keep those step titles unchanged; if you must rename one, grep `resources/shared/` for the old number and title in the same PR.
- Skill-specific data lives in the module's **config table**, keyed by `AGENT_SKILL`. Add a row for a new skill (product repo, test repo) in the same PR.

---

## Adding a new skill

1. Create `resources/skills/<name>/SKILL.md` following this structure (e.g., `resources/skills/my-operator/SKILL.md`)
2. Add an `OWNERS` file in `resources/skills/<name>/` listing your team as reviewers/approvers (each existing skill has its own)
   Also add the skill's row to the config table in `resources/shared/attribution.md`.
3. Lint the skill with skillsaw (see [Skill validation](#skill-validation))
4. Open a PR to `openshift/release`
5. Set `AGENT_SKILL: <name>` in your CI config (e.g., `AGENT_SKILL: my-operator`)

Skill directory names must match `^[A-Za-z0-9_-]+$`. The step rejects any value with other characters.

---

## Skill validation

Before submitting a new or modified skill, run [skillsaw](https://github.com/stbenjam/skillsaw) lint locally. Skillsaw checks skill files for security issues (embedded secrets), content quality (weak language, contradictions, attention dead zones), and structure (frontmatter, instruction budget limits).

### Running skillsaw lint

Run skillsaw directly from the qe-agent step directory, either installed locally (`pip install skillsaw`) or with the container image:

```bash
cd ci-operator/step-registry/openshift-observability/qe-agent

# Lint one skill (or pass resources/skills to lint all of them)
skillsaw lint resources/skills/<name>

# Same, with Podman or Docker instead of a local install
podman run --rm -v "$(pwd):/workspace:Z" ghcr.io/stbenjam/skillsaw:latest lint resources/skills/<name>
```

Skillsaw runs with its default rules; there is no Makefile or `.skillsaw.yaml` here because the step registry only accepts registry files, `*.md` and `OWNERS` under `ci-operator/step-registry/`. A new or modified skill must lint without errors. The baseline is skillsaw's default `context-budget` limit of **6,000 tokens per `SKILL.md`** — keep skills under it (the rule also warns above 3,000 tokens; that warning is informational). If a change pushes a skill over the limit, move bulky shared procedures into a module under `resources/shared/` (referenced files do not count toward the budget) or tighten existing wording; do not drop required steps.

The step script fetches skills by directory name (e.g., `AGENT_SKILL: tempo` loads `resources/skills/tempo/SKILL.md`).

---

## Conventions

- **Use the shared pointers for Steps 0a, 1, 4 (cluster-instability criteria), 4a, 5a, 5b, 5c, 5d and 6** — the procedures are defined once, in `shared/`. Only the per-skill values (operator name and namespace in Step 5b, an extra classification in Step 6) differ. Do not inline a shared procedure back into a skill; change the module instead.
- **Operator diagnostics (Step 4) must be specific to your component** — use the correct namespace, deployment name, CR kinds, and CRD patterns for your operator.
- **Chainsaw skills must include `unset NAMESPACE`** before every `chainsaw test` call.
- **Each bash invocation starts a fresh shell** — re-declare variables (`TEST_DIR`, `GOPATH`, etc.) at the top of every bash block.
- **Use `--skip-delete` for chainsaw reruns** so resources remain on-cluster for inspection, but always clean up before the next rerun.
- **Cap analysis at 3 individual tests** when no common pattern is found in high-failure triage.
