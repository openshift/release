# Manifest-driven PR evals

The opt-in `openshift-claude-agent-eval-manifest` workflow reads `evals.yaml`
at the root of the repository under test. After one ci-operator job enrolls
that repository, contributors add evals through its manifest, eval YAMLs,
and cases, without another openshift/release test entry for each eval.

This implements the independent manifest PR workflow for PIXAA-23. The new
workflow uses a Python runner; the existing `openshift-claude-agent-eval`
workflow retains its original commands and environment interface unchanged.
PIXAA job/image wiring and seed evals/docs are separate tasks. Existing
workflow migration and periodic/manual eval execution are out of scope.

## Manifest contract

`manifest_runner.py` validates the contract; there is no separate JSON schema.

```yaml
evals:
- config: sdlc/plugins/sdlc-core/evals/eval-foo.yaml
  eval_cases_dir: sdlc/plugins/sdlc-core/evals/cases/foo
  run: pr
  parallelism: 5
  max_turns: 2500
  setup_script: sdlc/plugins/sdlc-core/evals/scripts/setup-foo.sh
  triggers:
  - sdlc/plugins/sdlc-core/
  - evals.yaml
```

`config`, `run`, `parallelism`, and `max_turns` are required; the latter two
are positive integers. `setup_script` and `eval_cases_dir` are optional.
`run` must be `pr`; `periodic` and `manual` entries are rejected before execution.
`triggers` is a nonempty list of literal path prefixes. `evals: []` is valid.
Unknown fields, duplicate YAML keys/configs, invalid types, missing paths,
and paths escaping the repository fail before any model calls.

Paths are relative to the repository root, without `./` or `..`. Triggers
use OR semantics: `skills/foo/` includes descendants but not `skills/foobar/`.
They are not globs or regular expressions. Include configs, cases, setup,
and shared dependencies as appropriate. Include `evals.yaml` explicitly if
manifest edits should trigger an eval; it has no implicit trigger behavior.

The diff is `git diff --name-only -z --no-renames PULL_BASE_SHA...HEAD`.
Renames include both paths; deletions count as changes. A missing base SHA
or failed diff is an error. No match exits 0 with a zero-test JUnit file,
without setup, harness installation, or Claude calls.

### Changed-case selection

After triggers select an eval, `eval_cases_dir` allows case-only changes to
select exact case IDs via `--cases`. IDs are sorted, deduplicated names of
immediate subdirectories, including cases with changed nested fixtures.
The directory must match the eval YAML's `dataset.path`, resolved relative
to that YAML (e.g. `cases/foo` in the example). The eval YAML is not rewritten.

The provisional policy, pending task-owner confirmation, is:

- Only individual cases change: run those cases.
- A trigger-matching change is outside individual cases: run the full dataset.
- For an already-selected eval, config/setup/manifest edits also force a full
  run, even when those paths are absent from its triggers.
- Shared files or removed/renamed case directories force a full run. Removing
  a fixture inside a surviving case selects that case. A missing entire
  `eval_cases_dir` is a configuration error.
- Without `eval_cases_dir`, run the full dataset.

The field adds no implicit triggers. Unrelated changes do not force a full
run. This policy lives in `select_cases()` so it can be revised independently.

## Configuration ownership

The manifest owns parallelism and setup. Setup runs once per selected eval
from the repository root; stdout becomes that eval's `EVAL_SNAPSHOT_DIR`.
Write setup diagnostics to stderr. Each eval receives a fresh environment.

**Turn-limit clarification:** `max_turns` currently limits the outer Claude
session running `/eval-run`. The ticket
says "per case", but the current harness exposes no per-case max-turns
argument. Strict per-case enforcement requires a coordinated harness change.

The harness receives the original eval YAML. Its `models.skill` supplies
`--model`; budget, timeout, judges, thresholds, permissions, effort, and
dataset remain harness-owned. In case mode, `execution.max_budget_usd` limits
each case invocation, not total CI spend or judge/orchestrator calls.
`CLAUDE_MODEL` chooses the outer orchestrator model.

The new step exposes no legacy scheduling/runner overrides. `EVAL_DISCOVER`,
an explicit non-default `EVAL_CONFIG`, and `EVAL_EXTRA_ARGS` are rejected.
Other legacy runner overrides do not override manifest/eval settings.
Existing jobs continue to use the unchanged `openshift-claude-agent-eval` workflow.

## CI integration

Select `workflow: openshift-claude-agent-eval-manifest`, supply its
`claude-ai-helpers` image, and start the step in the PR checkout root, including
`.git` and the base commit's history. An unset or empty `EVAL_WORKDIR` defaults
to the current working directory; set it explicitly when the checkout is
elsewhere. Relative overrides resolve from the starting directory. The runner
does not search for another checkout or fall back to `/opt/ai-helpers`.
No `EVAL_MANIFEST` flag is needed.

This workflow supports presubmit jobs only. Prow job configuration controls
whether PR creation, new commits on an open PR, or a manual test request
starts a job. Manually triggering a presubmit still uses `run: pr`; it does
not require a manifest `run: manual` mode. Postsubmit and periodic jobs are
not supported by this runner.

The job uses `skip_if_only_changed` for broad filtering and the manifest for
precise selection. Skills are Markdown, so do not exclude all `*.md` files.
The step reuses the existing Vertex/GitHub credential mounts, Python/PyYAML,
and `/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py` for AutoDL.
This extractor remains an image dependency, independent of the checkout path.

## Results

Evals run sequentially; parallelism applies to cases within each eval.
Each gets a unique run ID. Artifact directory names combine the config basename
and a path hash, so configs with the same basename remain separate:

```text
ARTIFACT_DIR/
  junit_claude-eval.xml
  claude-session-metrics-autodl.json  # when metrics are available
  evals-summary.html
  runner/harness-install.log
  evals/<artifact_name>/
    report-summary.html
    summary.yaml
    run_result.json
    claude-eval.log
    setup.log                       # if setup ran
    regression.log                  # if scoring ran
    metrics.log                     # if metrics extraction was attempted
    eval-run.tar
```

The static index links available artifacts and reports selected evals as passed,
failed, or not run. No matching evals and configuration errors also produce an
index. HTML reports retain the `-summary.html` suffix for Prow display.
When embedded in Prow's HTML lens, the index uses the lens's artifact path to
open files and directories in the OpenShift artifact browser in a new tab.
When opened directly or downloaded with its artifacts, links remain relative.
The eval's child processes receive its own directory as `ARTIFACT_DIR`; setup
scripts can write additional diagnostic files there. JUnit and AutoDL metrics
remain aggregated at the job root.

Each archive contains only the current eval's harness run under `run/`, including
partial results on failure. It uses an uncompressed `.tar` so CI artifact
processing preserves the filename used by the index. Other evals and historical
runs are not archived.
Files for stages that never ran are absent; the index only links existing files.
JUnit contains one testcase per attempted eval, not per dataset case.

This workflow does not provide session continuation or archive the global
Claude session directory. Eval reports, execution logs, and harness run
artifacts remain available for diagnosis.

Setup/process failures, incomplete results, and failed deterministic harness
regression checks fail the eval; subsequent evals still run. Any failure
fails the step. Deadline-expired evals are recorded as failures. SIGTERM/SIGINT
stop scheduling and terminate child processes while preserving available artifacts
when possible. Collection or archive failures fail that eval, retain existing
logs, and allow subsequent evals to run.
Python emits AutoDL metrics for orchestrator and harness model usage;
metrics failures remain warnings and do not replace the eval verdict.

## Development and validation

Edit `manifest_runner.py`, `eval_plan.py`, or `eval_metrics.py`, then run
`sync_commands.py`. It packages these sources into the manifest step's
commands script only; it does not read or write the existing workflow's
commands script. ci-operator ships a commands script's contents, not sibling
Python files from release/hack.
The shell unpacks the files and forwards signals; Python owns orchestration.
This avoids a runtime source download or a shared-image change. Packaging
the runner in an image later would allow removing this generator.

```bash
python3 hack/claude-agent-eval/sync_commands.py
python3 hack/claude-agent-eval/sync_commands.py --check
bash hack/claude-agent-eval/test-container.sh
pylint --rcfile=hack/.pylintrc --ignore=lib,image-mirroring --persistent=n hack
make validate-step-registry
make registry-metadata
```

Container tests default to the promoted `claude-ai-helpers:latest` CI image;
set `EVAL_TEST_IMAGE` to an immutable digest to reproduce a particular run.
Set `CONTAINER_ENGINE=docker` to use Docker instead of Podman. The tests run
with network disabled, fake Claude/harness executables, no mounted credentials,
and real Git/Python; they make no model calls and need no fake GNU `timeout`.
They cover the distributed manifest entry point, eval/case selection,
per-eval setup, and failure reporting. These offline tests do not establish
that the workflow works end to end in Prow with the real harness and models.

For a fast local run (Python 3.9+ and PyYAML):
`python3 -m unittest discover -s hack/claude-agent-eval -p 'test_*.py' -v`.
Run pylint against all of `hack`, as CI does. The separate Python validation
image currently uses Python 3.14 and unpinned pylint; older local versions
may miss checks enforced by CI.
