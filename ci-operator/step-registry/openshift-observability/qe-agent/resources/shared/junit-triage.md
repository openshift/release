# JUnit Parsing and High-Failure Triage (Step 1)

This is the body of Step 1, shared by every QE agent skill. The skill's Step 1 lists the root causes and error patterns that are typical for its suite. This module holds the procedure.

## Parse the JUnit files

Read all JUnit XML files matching `${SHARED_DIR}/qe-agent-junit-*.xml` (flat files copied by the test step's trap function). For each file, extract:

- **Suite name**: the `name` attribute on `<testsuite>`
- **Failed test cases**: `<testcase>` elements that contain a `<failure>` or `<error>` child
- **Failure message**: the `message` attribute and text body of `<failure>` / `<error>`
- **Stack trace / details**: the full text content of the failure element (including any `file:line` it cites)

Group failures by suite so you process each operator's failures together.

If no `${SHARED_DIR}/qe-agent-junit-*.xml` files exist, exit with a clear message: the test step did not run or produced no results.

## High-failure triage: more than 5 failures total

When more than 5 tests fail, they very likely share one root cause (an operator crash, a missing CRD, an install failure, a broken dependency) rather than being independent bugs. Look for a common pattern:

- the same error string in several failure messages,
- the same failing test step or command (the same framework step, resource or namespace),
- failure times clustered tightly, within seconds of each other.

Then:

- **Pattern found**: pick the **simplest failing test** (fewest steps, shortest failure message) as the representative case, record the pattern in the analysis summary, and proceed through Steps 2–5 for that test only.
- **No pattern**: process failures individually, cap at 3 tests, and note this in the summary.

Write the pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.
