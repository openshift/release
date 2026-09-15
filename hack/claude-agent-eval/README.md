# Manifest-driven PR evals

The opt-in `openshift-claude-agent-eval-manifest` workflow reads `evals.yaml`
at the root of the repository under test. After one ci-operator job enrolls
that repository, contributors add evals through its manifest, eval YAMLs,
and cases, without another openshift/release test entry for each eval.

This implements PIXAA-23. Both workflows use one Python execution engine.
The existing `openshift-claude-agent-eval` workflow keeps its name and env
interface through a temporary `legacy_adapter.py`; the dedicated manifest
workflow reads repo-owned inputs directly. PIXAA job/image wiring, seed
evals/docs, and migration of consumers to manifests are separate tasks.
Manifest periodic/manual execution is reserved for PIXAA-26.

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
`triggers` is a list of literal path prefixes, nonempty for `run: pr`.
`periodic` and `manual` entries are logged and skipped. `evals: []` is valid.
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
session running `/eval-run`, matching legacy `EVAL_MAX_TURNS`. The ticket
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
Use the existing workflow for legacy inputs until consumers migrate to manifests.

## Legacy input adapter

`openshift-claude-agent-eval` selects `--input legacy`; the new workflow
selects `--input manifest`. Both adapters produce `EvalPlan` objects for the
same setup, Claude, timeout, result validation, scoring, metrics, and artifact
code. Neither shell entry point contains an execution loop. Delete the legacy
adapter and its entry point once consumers have migrated to manifests.

The legacy adapter preserves:

- `EVAL_CONFIG`, `EVAL_DISCOVER` (including `true` and its default glob), and
  their mutual exclusion. A manifest and PR Git checkout are not required
  for single-config/manual or periodic legacy runs.
- `EVAL_MODEL`, `EVAL_EFFORT`, their nonempty Gangway overrides,
  `EVAL_PARALLELISM`, and `EVAL_MAX_TURNS`. Ref defaults remain unchanged;
  legacy eval YAMLs need not declare `models.skill`.
- `EVAL_CHANGED_ONLY`, `EVAL_CASES_DIR`, and comma-separated `EVAL_CASES`.
  Detected changed cases take precedence over explicit cases. Discovery uses
  `<config directory>/<config stem>/cases`; changed-only entries without
  detected or explicit cases are skipped. Unlike manifest mode, a skill-only
  change does not automatically run the full legacy dataset.
- `EVAL_BASELINE` and shell-style quoted `EVAL_EXTRA_ARGS`, parsed as argument
  values without executing shell code.
- `EVAL_SETUP_SCRIPT` once per selected job, sharing its snapshot directory
  across that job's evals. A failed shared setup is not retried. Manifest
  setup remains once per selected eval, with an independent environment.

The shared engine deliberately gives legacy runs the same failure reporting:
invalid diffs fail instead of silently skipping, no matches produce zero-test
JUnit, incomplete harness results and failed regression checks fail the job,
and deadlines do not silently drop remaining evals. Reports use per-eval names
instead of overwriting each other; the complete run archive remains available.
Existing jobs need no configuration changes to use the adapter.

## CI integration

Select `workflow: openshift-claude-agent-eval-manifest`, supply its
`claude-ai-helpers` image, and set `EVAL_WORKDIR` to the PR checkout root,
including `.git` and the base commit's history. The default `/opt/ai-helpers`
only works if it contains that checkout. No `EVAL_MANIFEST` flag is needed.

The job uses `skip_if_only_changed` for broad filtering and the manifest for
precise selection. Skills are Markdown, so do not exclude all `*.md` files.
The step reuses the existing Vertex/GitHub credential mounts, Python/PyYAML,
and `/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py` for AutoDL.

## Results

Evals run sequentially; parallelism applies to cases within each eval.
Each gets a unique run ID. Artifact names combine the config basename and
a path hash to avoid collisions. HTML reports end in `-summary.html` for
Prow display. The complete runs directory is archived as `eval-runs.tar.gz`.
JUnit contains one testcase per attempted eval, not per dataset case.

Setup/process failures, incomplete results, and failed deterministic harness
regression checks fail the eval; subsequent evals still run. Any failure
fails the step. Deadline-expired evals are recorded as failures. SIGTERM/SIGINT
stop scheduling and terminate child processes while preserving artifacts.
Python emits AutoDL metrics for orchestrator and harness model usage;
metrics failures remain warnings and do not replace the eval verdict.

## Development and validation

Edit `manifest_runner.py`, `eval_plan.py`, `legacy_adapter.py`, or
`eval_metrics.py`, then run `sync_commands.py`. It packages the same Python
sources into both steps' commands scripts, differing only in the selected
input adapter. ci-operator ships a commands script's contents, not sibling
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
They cover both distributed entry points, legacy overrides/case selection,
shared setup, and the manifest-specific contract.

For a fast local run (Python 3.9+ and PyYAML):
`python3 -m unittest discover -s hack/claude-agent-eval -p 'test_*.py' -v`.
Run pylint against all of `hack`, as CI does. The separate Python validation
image currently uses Python 3.14 and unpinned pylint; older local versions
may miss checks enforced by CI.
