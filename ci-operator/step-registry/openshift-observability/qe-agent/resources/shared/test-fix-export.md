# Test Fix and Export (Steps 5a and 5c)

This is the body of Step 5a (`TEST_ISSUE`) and Step 5c (`FLAKY`), shared by every QE agent skill. The skill's own step gives you the framework-specific fixes (which files to edit, common fixes, examples). This module holds the rules and the export format, which are the same for every skill.

## Fix a test (Step 5a, `TEST_ISSUE`)

Apply the **minimal** change that makes the test correct. Avoid refactoring or improving unrelated parts of the test: a focused, small diff is easier to review and merge. Do not change product code.

## Fix a flaky test (Step 5c, `FLAKY`)

Apply the minimal change that eliminates the race or timing condition. Do not suppress flakiness with blanket retries: find and fix the root cause. Prefer a condition-based wait on the state the assertion needs over a fixed sleep or a longer fixed timeout. Then export as below, and use the pass/fail pattern from the 4 reruns as evidence in `CHANGES.md`.

## Export the fix

Copy only the changed files to `${ARTIFACT_DIR}/test-fixes/`, **preserving the directory path relative to the repo root** (run this from the repo root):

```bash
# Example: tests/e2e/<folder>/<file> was fixed (re-declare the values, each bash call is a fresh shell)
changed="tests/e2e/<folder>/<file>"
dest="${ARTIFACT_DIR}/test-fixes/$(dirname "${changed}")"
mkdir -p "${dest}"
cp "${changed}" "${dest}/"
```

Then write `${ARTIFACT_DIR}/test-fixes/CHANGES.md`:

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
- `<path relative to the repo root>`

## Pass/fail pattern
<for FLAKY only: the pattern from the 4 reruns, e.g. PFPP>

## Suspected Introducing Change
<only when the attribution module ran in Step 4a: its table and caveat, see attribution.md>

## Verification
Rerun result after fix: [PASS / FAIL / not re-verified]
```

Omit **Pass/fail pattern** for `TEST_ISSUE` and **Suspected Introducing Change** if Step 4a produced no section. If several tests are fixed, list each under its own heading in the one `CHANGES.md`.
