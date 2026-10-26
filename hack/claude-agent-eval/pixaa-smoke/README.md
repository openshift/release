# PIXAA consumer rehearsal

This test-only release variant exercises the merged
`openshift-claude-agent-eval-manifest` runner against PIXAA PR #51
(`pixaa-23-manifest-consumer-smoke`). It does not enroll a permanent PIXAA job
and does not change the shared step registry or the legacy runner.

## How it runs

The variant builds a test image from `ci/claude-ai-helpers:latest`, the image
the registry ref runs in, and copies two files into it from this checkout: the
registry's generated `openshift-claude-agent-eval-manifest-commands.sh`, byte
for byte, and the bootstrap `consumer-env.sh` next to this README. The test
`eval-pixaa-smoke` then runs one inline step that mirrors the ref's `from`,
environment, resources, timeout, and credentials, sources the bootstrap, and
`exec`s the copied commands. The step adds one credential the ref does not
have: the `ci` namespace bundle
`github-credentials-openshift-ci-robot-private-git-cloner`, mounted at
`/usr/local/github-credentials`. ci-operator cannot add credentials to a
referenced step from a job, so the rehearsal carries that mount on its own
inline step instead of patching the shared ref.

The image contains only the bootstrap and the runner; PIXAA is fetched at
runtime with the private Git cloner token. The bootstrap pins the consumer head
and base, validates the fetched history, and switches the runner's
`PULL_BASE_SHA` to the consumer base while preserving Prow's release job
identity. Logs record both consumer and release revisions in
`runner/consumer-inputs.log`. A failed fetch is an infrastructure or access
failure, not a passed eval.

Credentials are not embedded in the image, remote URL, or Git configuration.
Git obtains `/usr/local/github-credentials/oauth` through a temporary askpass
helper which is removed after the fetch. The CI identity still needs read
access to PIXAA; the developer's ability to read it does not establish that
permission. The test uses public Prow artifacts, as agreed for this smoke run.

## Pins

| Input | Value |
| --- | --- |
| Consumer PR | openshift-eng/pixaa#51 |
| Consumer head | `b0da4950691f2cf317e5bd30078e25094838209e` |
| Consumer base | `c88c63715cdc84e3fb5360c6094a5c49468e3e8c` (merge base with pixaa `main`) |
| Runner | the `openshift-claude-agent-eval-manifest` commands at this branch's base on `main` |

Update `EVAL_SMOKE_HEAD` and `EVAL_SMOKE_BASE` in `consumer-env.sh` to retarget
a rehearsal. The base must be the head's merge base with pixaa `main`:

```bash
gh api repos/openshift-eng/pixaa/compare/main...<head> --jq .merge_base_commit.sha
```

## Running and reading it

Rehearse from the release PR with
`/pj-rehearse pull-ci-openshift-release-main-pixaa-manifest-smoke-eval-pixaa-smoke`.
Expected result: one selected eval with two scored cases, both passing, plus
aggregate JSON/HTML/JUnit and one per-eval artifact bundle under
`artifacts/eval-pixaa-smoke/openshift-claude-agent-eval-manifest/artifacts/evals/`.
Check the artifact links and the checkout provenance in
`runner/consumer-inputs.log`.

To validate one changed case, the consumer base must already contain the
fixture, for example via a stacked PR. Merely adding a case edit to the initial
fixture PR still runs the full dataset because selection uses the complete PR
diff. Pin each subsequent test's consumer head and base explicitly.
