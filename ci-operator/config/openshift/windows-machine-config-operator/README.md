# WMCO CI configuration

## Opt-in AWS UPI BYOH OTE debugging

The `aws-upi-e2e-byoh-ote-debug` test in the `master__ote` configuration is
an optional, manually requested presubmit. Request it on a WMCO pull request
with `/test ote-aws-upi-e2e-byoh-ote-debug`. It has no automatic file-change
trigger or periodic schedule; the normal BYOH OTE job is unchanged.

It uses the same `windows-e2e-ote-byoh-pool-aws-upi` workflow, PR-built test
extension, BYOH environment setup, and test suite as `aws-upi-e2e-byoh-ote`.
After the extension and environment setup, the existing `wait` step pauses
before `openshift-e2e-test`. `PR_ONLY: "true"` restricts waiting to presubmits,
and `TIMEOUT: +4 hours` sets the hold itself to four hours. The wait script
checks once per minute, so release can lag the deadline by about a minute.
To resume early, an authorized operator can run `touch /tmp/debug.done` in
the **wait pod's** terminal. This does not require changing the test or
publishing credentials; the wait step does not publish access credentials.

The debug job has a separate 20-hour Prow timeout, rather than using the
four-hour hold as the whole-job deadline. This leaves 16 hours outside the
hold for builds and provisioning, the existing four-hour e2e step, gathering,
and teardown. The explicitly bounded gather steps allow up to 4 hours
45 minutes combined, and `ipi-deprovision-deprovision` allows one hour,
leaving 6 hours 15 minutes for other setup/cleanup steps and overhead.
These are planning allowances, not a guarantee against infrastructure delays.
The unchanged post chain gathers diagnostics, destroys the BYOH node-pool
hosts, then deprovisions the cluster. Let the job resume and finish normally
to preserve this cleanup; do not cancel it as a substitute for releasing
the wait. The debug variant does not change pool reservations or access policy.
