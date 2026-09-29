# Product Bug Report and Jira Payload (Step 5b)

This is the body of Step 5b, shared by every QE agent skill. Run it for each diagnosed root cause classified as `PRODUCT_BUG`. The skill's Step 5b gives you the operator name and namespace for the **Affected component** section.

Do not attempt to fix operator or plugin code. Write the report instead.

## 1. Bug report

Write `${ARTIFACT_DIR}/bug-report.md`. If Step 1's "No pattern" branch is diagnosing more than one test individually, write a distinct `${ARTIFACT_DIR}/bug-report-<case-id>.md` per `PRODUCT_BUG` test instead (use the test's case ID if the skill defines one, otherwise a short slug of the test name), so multiple diagnoses don't overwrite each other.

````markdown
> **AI-Generated Content** — This analysis was produced by the OpenShift Observability QE Agent (Claude Code CLI). Always review AI-generated output prior to use.

# Product Bug Report

## Summary
<one-sentence description of the bug>

## Affected component
- Operator: <operator name from the skill's Step 5b>
- Namespace: <namespace from the skill's Step 5b>
- Failing test: <suite / test case>

## Reproduction
1. <Step-by-step reproduction based on what the test does>

## Observed behavior
<What happened — include the exact failure message from JUnit, and the framework error (for example the Cypress error) when there is one>

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

## Suspected Introducing Change
<only when the attribution module ran in Step 4a: its table and caveat, see attribution.md>

## Suggested severity
<Critical / Major / Minor — based on whether this blocks a release gate>
````

Omit **Suspected Introducing Change** if Step 4a produced no section. Its content comes from `attribution.md` and must be in the report before you convert it into the Jira payload.

## 2. Jira payload

The wrapper files the Jira issue from `${ARTIFACT_DIR}/jira-payload.json`. It reads only this fixed filename, and only its `summary` and `description` fields (the `severity` field is ignored). Write **one** payload per run: combine multiple `PRODUCT_BUG` reports into a single Jira issue, one subsection per test, rather than per-test payloads.

Convert the bug report to **Jira wiki notation**:

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
| Markdown table: `\| A \| B \|` header, `\|---\|---\|` separator, rows `\| 1 \| 2 \|` | header `\|\|A\|\|B\|\|` (drop the separator row), rows `\|1\|2\|` |

Write the JSON with `jq` for safe escaping:

```bash
_SUMMARY="[qe-agent] <one-sentence summary — for multiple bugs, e.g. 'N product bugs found in <suite>'>"
# Summary must be ≤ 255 characters
_SUMMARY="${_SUMMARY:0:255}"
_DESCRIPTION="<bug report(s) in Jira wiki notation, starting with '*Severity:* <level>'; for multiple bugs, concatenate each under its own 'h2. <test case>' heading>"

jq -n \
  --arg summary "${_SUMMARY}" \
  --arg description "${_DESCRIPTION}" \
  --arg severity "<Critical / Major / Minor — highest severity among the combined bugs>" \
  '{summary: $summary, description: $description, severity: $severity}' \
  > "${ARTIFACT_DIR}/jira-payload.json"
```

Neither the bug report(s) nor the Jira description may contain raw credentials, tokens, passwords, or SHA-256 digests. Redact them as `[REDACTED]` in every evidence excerpt (operator logs, cluster events, JUnit failure text) before writing any of these files.
