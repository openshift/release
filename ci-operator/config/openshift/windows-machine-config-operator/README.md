# WMCO CI configuration

## Opt-in AWS TLS adherence OTE debugging

The `aws-e2e-ote-tls-debug` test in the `master__ote` configuration is an
optional, manually requested presubmit. Request it on a WMCO pull request with
`/test ote-aws-e2e-ote-tls-debug`. It has no automatic file-change trigger or
periodic schedule; the normal `aws-e2e-ote-tls` job is unchanged.

It keeps the `aws-e2e-ote-tls` topology and steps: the same `ipi-aws-ovn-hybrid`
workflow with three control-plane nodes and one compute node, the same
`enable-tls-adherence` step, `wmco-setup-and-test` using the PR-built
`windows-machine-config-operator-test` image, and the unchanged
`wmco-tls-adherence-tests` command, which runs the
`windows-machine-config-operator/tls-adherence` suite with `--max-concurrency 1`.
The existing `wait` step is inserted after `wmco-setup-and-test` and before
`wmco-tls-adherence-tests`. `PR_ONLY: "true"` restricts waiting to presubmits,
and `TIMEOUT: +4 hours` sets the hold to four hours. The wait script checks once
per minute, so release can lag the deadline by about a minute. To resume early,
an authorized user can run `touch /tmp/debug.done` in the wait pod's terminal.
When the hold ends, the TLS suite runs exactly as in the normal job. Because
the debug test is a copy, any change to `aws-e2e-ote-tls` must be mirrored in
`aws-e2e-ote-tls-debug`.

The debug copy of `wmco-setup-and-test` also differs from the normal job. It
configures Windows nodes through the ConfigMap path only
(`-m 0 -c 1`); the Machine path's SSH availability probe has timed out in this
environment and `create_test.go` skips that path when the machine node count is
zero. When setup still fails it writes the probe Job, its pods, events, nodes,
machines and the WMCO operator log to `${ARTIFACT_DIR}/wmco-setup-failure`, then
holds the step open for `TIMEOUT` or until `/tmp/debug.done` exists, and finally
exits with the original setup status. The step clears `errexit` before running
the setup script, so a failing setup still reaches the capture and the hold. Its step limit is 6h45m, covering the 2h15m setup budget,
the four-hour hold and the capture. A failed setup therefore fails the job and
stays inspectable before the post steps remove the cluster; a successful setup
goes straight to the `wait` step. The failure capture and the in-step hold exist
only in this debug variant.

The debug job has a 20-hour Prow timeout instead of the default. Besides the
four-hour hold, this leaves time for image builds, installation, TLS enablement,
WMCO setup (6h45m step limit in this variant), the TLS suite (4h30m step limit), gathering
(`gather-must-gather` and `gather-extra` up to 2h each, `gather-audit-logs` 15m)
and `ipi-deprovision-deprovision` (1h). These are planning allowances, not a
guarantee against infrastructure delays. The unchanged post chain gathers
diagnostics and deprovisions the cluster; let the job finish normally instead of
cancelling it as a substitute for releasing the wait.

For each pull request author in the tested refs, ci-operator binds the `admin`
role in the test namespace to a group named `<github-login>-group`; access
depends on that group's membership on the build cluster. A rehearsal of this
job from an openshift/release pull request tests the WMCO base branch, not a
WMCO pull request, and its only pull request author is the author of the
openshift/release pull request. A rehearsal still provisions a cluster and
holds it for four hours, so request one only when that is intended. To debug a
specific WMCO pull request, request the job on that WMCO pull request once this
configuration is available in Prow.
