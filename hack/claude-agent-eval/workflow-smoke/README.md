# Temporary cross-repository workflow rehearsal

This test-only wiring in release exercises the candidate
`openshift-claude-agent-eval-manifest` workflow against
[ai-helpers PR #765](https://github.com/openshift-eng/ai-helpers/pull/765).
The manifest, eval configs, cases, and full code-review plugin come from that
checkout. No eval fixture or root `evals.yaml` is copied into release.

The optional, manually requested job is defined in
`ci-operator/config/openshift/release/openshift-release-main__manifest-smoke-workflow.yaml`.
Its job-local image uses the existing Claude runtime and checks out these pinned
ai-helpers revisions:

- Base: `b3ec8bbc4d7b947fd6f18dd13339d9acbb8c37ce`
- PR head: `da76969fe72f0bd8b560383a93d48fa96dc15815`

The CI image build fails if the base is missing or is not an ancestor of the
head. `/workspace` contains the writable checkout and Git history.

## Why the test image has a shell bootstrap

Prow rehearses a release PR, so its primary refs and injected `PULL_BASE_SHA`
describe release. Merely checking out ai-helpers would make the runner diff
against the wrong repository's commit. This temporary image sets `BASH_ENV` to
`consumer-env.sh`, which Bash sources before executing the registry commands.
It checks the checkout, records both repositories' revisions in
`runner/consumer-inputs.log`, and sets `PULL_BASE_SHA` to the pinned consumer
base. It unsets `BASH_ENV` so child shells do not repeat the bootstrap.

This bootstrap exists only in the unpromoted test image. The shared image,
runner, workflow, ref, credentials, and generated commands are unchanged.
There is no inline replacement for the workflow's test commands. Prow's
`JOB_SPEC` and release PR reporting identity remain unchanged.

## Run and verify

Request on the release testing PR:

```text
/pj-rehearse pull-ci-openshift-release-main-manifest-smoke-workflow-eval-manifest-smoke
```

Verify that the resolved workflow uses the candidate commands, that
`consumer-inputs.log` identifies the revisions above, and that both evals
actually run. They deliberately share their name and output filename, with
different expected classifications, to check artifact isolation. Require two
passing JUnit cases, separate complete eval bundles, and working index links.
A green run with zero selected evals does not satisfy the test.

This remains a small consumer smoke test, not PIXAA enrollment or a broad
evaluation suite. It does not install an automatic job on ai-helpers PRs.
Before merging the feature, keep this temporary CI config, generated jobs,
and directory out of the feature PR.
