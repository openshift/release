# JUnit Parsing and High-Failure Triage (Step 1)

This is the body of Step 1, shared by every QE agent skill. The skill's Step 1 lists the root causes and error patterns that are typical for its suite. This module holds the procedure.

## Parse the JUnit files

Read all JUnit XML files matching `${QE_JUNIT_DIR}/qe-agent-junit-*.xml` (pod-local copies). The qe-agent wrapper moved these files out of `SHARED_DIR` before you started — `SHARED_DIR` is a 1 MiB Kubernetes Secret that is synced when this pod exits — so they are pod-local plain XML and are not in `SHARED_DIR`. Never write into `${SHARED_DIR}`: keep scratch files in `/tmp` and results in `${ARTIFACT_DIR}`. For each file, extract:

- **Suite name**: the `name` attribute on `<testsuite>`
- **Failed test cases**: `<testcase>` elements that contain a `<failure>` or `<error>` child
- **Failure message**: the `message` attribute and text body of `<failure>` / `<error>`
- **Stack trace / details**: the full text content of the failure element (including any `file:line` it cites)

Group failures by suite so you process each operator's failures together.

When `junit_truncated` is `true` in `${SHARED_DIR}/qe-agent-context.json`, the reports did not fit `SHARED_DIR` and were not copied at all. Say so in the analysis and point the reader to the full report (path in `junit_full_report`, under the test step's artifacts) — it is only readable by humans, it is not mounted in this step.

If no `${QE_JUNIT_DIR}/qe-agent-junit-*` files exist, exit with a clear message: the test step did not run or produced no results, its reports were too large for `SHARED_DIR` (`junit_truncated` is `true` in the context file), or its image could not reduce them (`junit_skipped` names the reason — `no-xsltproc`, `xsl-unwritable` or `reduce-failed`). Name the reason from the context file, do not guess.

## High-failure triage: more than 5 failures total

When more than 5 tests fail, they very likely share one root cause (an operator crash, a missing CRD, an install failure, a broken dependency) rather than being independent bugs. Look for a common pattern:

- the same error string in several failure messages,
- the same failing test step or command (the same framework step, resource or namespace),
- failure times clustered tightly, within seconds of each other.

Then:

- **Pattern found**: pick the **simplest failing test** (fewest steps, shortest failure message) as the representative case, record the pattern in the analysis summary, and proceed through Steps 2–5 for that test only.
- **No pattern**: process failures individually, cap at 3 tests, and note this in the summary.

Write the pattern conclusion near the top of `${ARTIFACT_DIR}/qe-agent-analysis.md`.
