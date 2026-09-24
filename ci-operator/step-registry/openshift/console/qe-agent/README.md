# OpenShift Console QE Agent

This post-step investigates failed Playwright tests against the cluster that the
same `e2e-gcp-console` job provisioned. It reuses the `console-tests` image and
produces a root-cause analysis, a proposed patch, and independently verified
rerun evidence. Human review is required before applying a patch. The original
test status is never changed.

The Console test step keeps its inline `./test-prow-e2e.sh` command. Once that
step finishes, the agent reads its `finished.json` and Prow JUnit XML from the
job's public GCS artifacts, plus bounded Playwright `error-context.md` files
and screenshots for matched failures. It uses the exact job's 14-day
`/api/bulk-prompt` history as supporting evidence, repeats selected tests on
unmodified code, and runs the
standalone `SKILL.md` in the step registry and
`ci-operator/config/openshift/console/tools/openshift-console-qe-agent-driver.py`
from the same pinned release commit. The step registry embeds the shell
commands but does not mount neighboring files, so the short shell entrypoint
downloads the Python driver from that immutable commit before
reading the completed test artifacts. Console-repository skills are never
loaded. Only test and helper changes are accepted. After the agent exits, a fresh checkout applies the candidate
patch, checks lint/types, and runs each target five times with retries disabled
plus its containing spec once. The wrapper prints a large success banner only
when all checks pass. Before verification it checks that the agent has not
changed the wrapper code or original test selection and resets any
agent-supplied verification status.

## Rollout

The ref defaults to `CONSOLE_FLAKE_AGENT_ENABLED=false`. Main's standard job
sets `CONSOLE_FLAKE_AGENT_ENABLED=rehearsal` before rollout. This runs the
agent only in a matching `openshift/release` PR rehearsal, using that PR's
immutable head SHA to fetch the driver and skill. A passing e2e test still
invokes no model. A failed e2e test receives the same investigation and
independent verification as a normal run. After the rehearsal is reviewed and
the step is merged, set `CONSOLE_FLAKE_SKILL_REVISION` to the full 40-character
merged commit containing the reviewed driver and skill, then set
`CONSOLE_FLAKE_AGENT_ENABLED=true` on main's standard job. TechPreview and
release-branch jobs are outside this pilot.

The main job is marked rehearseable, so an `openshift/release` PR can run
`/pj-rehearse pull-ci-openshift-console-main-e2e-gcp-console`. A rehearsal
uses a `rehearse-<release PR number>-...` job name and stores its test artifacts
under the release PR's Prow path. The driver recognizes that path and still
queries the normal Console main job for historical data.

`CONSOLE_FLAKE_HISTORY_DAYS` defaults to 14 (1–90), and
`CONSOLE_FLAKE_VERIFY_RUNS` defaults to 5. The model call is capped at $5 and
shares a 60-minute investigation window with baseline repeats. Independent
verification has 30 minutes; finalization has 10 minutes, for a 100-minute
outer timeout. A successful test or disabled agent uses no model budget.

Artifacts in the post-step's `ARTIFACT_DIR` are
`console-flake-analysis.md`, `console-flake-result.json`, optional
`console-flake-fix.patch`, `console-flake-evidence/`, `qe-agent-usage.json`,
`qe-agent-commands.log`, and `claude-session-metrics-autodl.json`. Experimental
reruns are not published as JUnit files, so they cannot affect Prow or the
dashboard's historical counts. Credentials and full model transcripts are not
uploaded. The audit log records tool commands, file paths, and search patterns
without tool output; the usage file contains cost and token metadata without
the model's response text. Both are derived from a temporary transcript that
the wrapper deletes when the step exits.

The Observability QE Agent README supplies the CI pattern, but this is a
separate step: it downloads the completed test step's public artifacts instead
of copying JUnit files through the 1 MiB `SHARED_DIR` Secret; it uses one
pinned Console skill instead of the Observability `AGENT_SKILL` selector; and
it does not configure Jira or other publishing integrations. The post-step
needs Prow job, build, and pull identity, and treats missing artifacts as
incomplete evidence. It never changes the original test result.

The Claude invocation uses `--bare`, `--disable-slash-commands`, an empty
settings source, and strict MCP configuration to avoid loading instructions
from the Console checkout. The agent has shell access to a disposable CI pod
and test cluster, so only run this on ephemeral test jobs. The post-step is
best-effort and precedes `ipi-gcp-post` to preserve teardown.

Validate the skill with `skillsaw lint SKILL.md`; also
run the focused checks with
`python3 ci-operator/config/openshift/console/tools/test_console_flake_agent.py`,
shell checks, `hack/validate-ai-metrics.sh`, registry/config validation, and a
controlled live-cluster rehearsal before enabling the pilot.
