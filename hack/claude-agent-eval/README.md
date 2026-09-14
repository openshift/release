# Manifest-driven PR evals

The `openshift-claude-agent-eval` workflow can read **`evals.yaml` at the
root of the repository under test**. Once a repository's ci-operator job
enables `EVAL_MANIFEST: "true"`, contributors enroll evals by changing that
repository's manifest, eval configurations, and cases. They do not need a
new openshift/release test entry for each eval.

This implements PIXAA-23. PIXAA's job/image wiring, seed eval, contributor
guide, and migration of ai-helpers are separate tasks. Periodic and manual
execution are reserved for PIXAA-26; this runner only schedules PR evals.

## Manifest contract

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

`evals.schema.json` describes the structure. `config`, `run`, `parallelism`,
and `max_turns` are required. The latter two must be positive integers.
`setup_script` and `eval_cases_dir` are optional. `triggers` is a list of literal path prefixes
and must be nonempty for `run: pr`. `run: periodic` and `run: manual` are
recognized but skipped, with a reason in the log. `evals: []` is valid.
Unknown fields, duplicate YAML keys/config paths, invalid types, missing
files, and paths escaping the repository fail before any model calls.

Paths are relative to the repository root, without `./` or `..`. A trigger
such as `skills/foo/` includes that directory's descendants, not
`skills/foobar/`. These are prefixes, not globs or regular expressions.
Multiple triggers use OR semantics. Include eval configs, cases, setup
scripts, and shared dependencies in the triggers as appropriate. A manifest
edit has no implicit special behavior: explicitly include `evals.yaml` to
rerun an eval when the manifest changes, as above.

The runner computes `git diff --name-only -z --no-renames PULL_BASE_SHA...HEAD`.
Renames include both paths, and deletions count as changes. A missing base SHA or failed diff is an
error, never a successful no-op. No match exits 0 with a zero-test JUnit file,
without running setup, cloning the harness, or starting Claude.

### Changed-case selection (provisional policy)

`eval_cases_dir` enables changed-case filtering **after** an eval's triggers
match. It must be an existing repository-relative directory and must resolve
to the same directory as the eval YAML's `dataset.path`. The harness resolves
`dataset.path` relative to the eval YAML, whereas the manifest path is relative
to the repository root. In the example above, the eval YAML would contain:

```yaml
dataset:
  path: cases/foo
```

The runner does not rewrite this configuration or override its dataset.
Case IDs are the full names of immediate subdirectories, matching the harness's
`--cases <id> [<id> ...]` interface. For example, editing
`evals/cases/foo/case-001-example/annotations.yaml` selects `case-001-example`.
The selection is sorted and deduplicated, and includes nested fixture changes.

The current policy, pending mentor confirmation, is:

- When only individual cases change for an eval, run the changed cases.
- When a trigger-matching change is outside those cases (skill, shared setup,
  dependency, etc.), run the entire dataset. Unrelated changes outside this
  eval's triggers do not force a full run.
- Once an eval is selected, changes to its config, setup script, or the root
  manifest also force a full run, even if not listed in its triggers.
- A shared file directly under the cases directory, a removed/renamed case
  directory, or an ambiguous case path causes a full run. Removing a fixture
  inside a surviving case still selects just that case. Removing the entire
  cases directory is a configuration error; it is not a successful no-op.
- Without `eval_cases_dir`, selected evals continue to run their full dataset.

This field does not add implicit triggers. Include the cases directory in
`triggers` if it is outside an already-covered path. This avoids silently
changing scheduling when adding the field. The policy is isolated in
`select_cases()` so it can be revised without changing the execution pipeline.

## Configuration ownership

Manifest settings determine case parallelism and the optional pre-eval setup.
Setup runs once per selected eval from the repository root. To preserve the
existing setup contract, stdout becomes `EVAL_SNAPSHOT_DIR` for that eval;
write diagnostics to stderr. Each eval starts with a fresh environment, so
one eval's snapshot directory does not leak into another.

**Turn-limit clarification:** `max_turns` currently caps the *outer Claude
session running `/eval-run`*, matching the existing `EVAL_MAX_TURNS` behavior.
PIXAA-23's text says "per case", but the current harness does not expose a
per-case max-turns argument. Do not describe this implementation as enforcing
per-case turns. Confirm this contract with the task owner; strict per-case
support needs a coordinated harness change.

The eval YAML is passed unchanged to `/eval-run`. `models.skill` is required
for selected evals and provides the `--model` argument. Budget, timeout,
permissions, judges, thresholds, runner effort, and dataset remain owned by
the harness. In case mode, `execution.max_budget_usd` caps each invocation,
not total CI job spend or judge/orchestrator calls. `CLAUDE_MODEL` still
selects the outer orchestrator model.

`EVAL_MODEL` (including Gangway overrides), `EVAL_PARALLELISM`,
`EVAL_MAX_TURNS`, `EVAL_SETUP_SCRIPT`, `EVAL_EFFORT`, `EVAL_CASES`,
`EVAL_CASES_DIR`, `EVAL_CHANGED_ONLY`, and `EVAL_BASELINE` do not override
manifest runs. `EVAL_EXTRA_ARGS` is rejected to prevent bypassing config
ownership. `EVAL_DISCOVER` and a non-default `EVAL_CONFIG` conflict with
manifest mode. With `EVAL_MANIFEST` disabled, the existing single-config and
deprecated discovery paths retain their behavior and overrides.

## CI integration requirements

The consuming ci-operator entry uses the existing workflow, supplies its
`claude-ai-helpers` image, sets `EVAL_MANIFEST: "true"`, and sets `EVAL_WORKDIR`
to the root of the **PR checkout with Git history**, including its base commit.
The current default `/opt/ai-helpers` only works if that directory contains
the required checkout. Copying source files without `.git` is insufficient.

The job's `skip_if_only_changed` should start the job for functional changes;
the manifest handles precise selection. Skills themselves are Markdown, so
do not exclude all `*.md` files as documentation. Existing Vertex credentials,
Python/PyYAML installation, and `/opt/ai-helpers` metrics extractor are reused.

## Results and failures

Selected evals run sequentially; `parallelism` controls cases within an eval.
Each gets a unique run ID. Artifact names use the config basename plus a hash
of its full relative path, so equal basenames in different plugins cannot
overwrite each other's reports. The HTML filename ends in `-summary.html`
for Prow's report display. Logs, summaries and result JSON are also namespaced.
The full runs tree is archived as `eval-runs.tar.gz`.

`junit_claude-eval.xml` has one testcase per attempted eval (not per dataset
case); setup/process/missing-result failures are recorded and subsequent evals
continue. The runner also invokes the harness's deterministic
`score.py regression` command to check thresholds without making new judge
calls. An outer Claude exit code of zero alone is insufficient for success.
Any failure makes the step exit nonzero. Eval runs that cannot start within
the step time allowance are failures rather than silently omitted work.
SIGTERM/SIGINT stop scheduling, terminate the active process group, and attempt
to preserve JUnit and artifacts within Prow's grace period.

The Python runner invokes the shell's exported `write_eval_metrics` function
to preserve existing AutoDL cost accounting. That function is removed from
the environment passed to setup scripts and Claude. Metric extraction errors
remain warnings, as in the legacy mode.

## Development and validation

Edit `manifest_runner.py`; do not hand-edit its generated copy in the step.
Following the existing `hack/art-manifests-validate` packaging pattern, the
generator embeds Python in the distributed commands script. No new runtime
download, image rebuild, or assumption that Prow mounts sibling files is needed.

```bash
python3 hack/claude-agent-eval/sync_commands.py
python3 hack/claude-agent-eval/sync_commands.py --check
python3 -m unittest discover -s hack/claude-agent-eval -p 'test_*.py' -v
bash -n ci-operator/step-registry/openshift/claude/agent-eval/openshift-claude-agent-eval-commands.sh
pylint --rcfile=hack/.pylintrc --ignore=lib,image-mirroring --persistent=n hack
```

Run pylint from the repository root against `hack`, as the CI job does; listing
only this directory's Python files can hide sibling-module import failures.
The CI validation image uses Python 3.14 and installs pylint without a version
pin, so an older local pylint may not report all checks enforced by CI.

The tests use temporary Git repositories and fake Claude/harness executables;
they do not call model APIs. Only PyYAML is required. Full repository checks
also include `make validate-step-registry` and `make registry-metadata` using
the container tooling described in the repository's contribution guidance.
