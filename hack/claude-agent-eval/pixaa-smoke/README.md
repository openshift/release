# PIXAA consumer rehearsal

This test-only release variant exercises the actual
`openshift-claude-agent-eval-manifest` workflow against PIXAA PR #51. It depends
on the runner in release PR #85160 and is separate from the AI Helpers rehearsal
in #85626. It does not enroll a permanent PIXAA job or change the legacy runner.

The image contains only the bootstrap; PIXAA is fetched at runtime using the
platform's dedicated private Git cloner token. `BASH_ENV` runs that bootstrap
before the unchanged registry commands, then is unset. The checkout validates
the pinned head and base history and switches the runner's `PULL_BASE_SHA` to
the consumer base while preserving Prow's release job identity. Logs record
both consumer and release revisions. A failed fetch is an infrastructure/access
failure, not a passed eval.

The test uses public Prow artifacts, as agreed for this smoke run. Credentials
are not embedded in the image, remote URL, or Git configuration. Git obtains
`/usr/local/github-credentials/oauth` through a temporary askpass helper which
is removed after the fetch. The CI identity still needs read access to PIXAA;
the developer's ability to read it does not establish that permission.

This rehearsal branch adds the `ci` namespace bundle
`github-credentials-openshift-ci-robot-private-git-cloner` to the manifest ref's
credentials. ci-operator does not support adding credentials to a referenced
step from an individual job. This mount is test-branch-only and must not be
carried into runner PR #85160. The runner commands, workflow, existing eval
credentials, and `GITHUB_TOKEN_PATH` are unchanged. The initial rehearsal's
eval bot token returned `Repository not found` when fetching PIXAA; this run
tests whether the dedicated cloner has the required access.

Expected initial result: one selected eval with two scored cases, both passing,
plus aggregate JSON/HTML/JUnit and one per-eval artifact bundle. Check artifact
links and the checkout provenance in `runner/consumer-inputs.log`.

To validate one changed case, the consumer base must already contain the
fixture, for example via a stacked PR. Merely adding a case edit to the initial
fixture PR still runs the full dataset because selection uses the complete PR
diff. Pin each subsequent test's consumer head/base explicitly.
