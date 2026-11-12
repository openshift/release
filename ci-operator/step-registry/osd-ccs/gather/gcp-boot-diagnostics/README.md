# Bounded GCP boot-signal observations for OSD CCS GCP clusters

`osd-ccs-cluster-provision-gcp` treats the mere existence of a compute instance
as bootstrap progress: once `gcloud compute instances list` matches the cluster
name, its bootstrap check short-circuits for the rest of the run. A worker
instance can therefore be created, never finish booting, never join the
cluster, and leave no guest-level evidence before the post phase deletes the
cluster. This step records a bounded, allow-listed summary of what the
instances reported on their serial console while they still exist.

Lint the delivered script from the repository root:

```sh
shellcheck ci-operator/step-registry/osd-ccs/gather/gcp-boot-diagnostics/*commands.sh
```

## Disabled by default, and why

The collector is gated behind `OSD_CCS_GATHER_GCP_BOOT_DIAGNOSTICS`, which must
be exactly `"true"`. Any other value, including the default, short-circuits the
step before it reads a credential file, authenticates, or issues a cloud API
call; it writes `{"collector":"disabled","reason":"opt_in_required"}` and exits
0. The default-off state is deliberate: it keeps the code reviewable and
testable while the decision to spend cloud reads from CI remains open.

**Enabling this step is not covered by the review of this change.** Before the
switch is turned on for any job, two things need an authorized answer:

- **Permission.** The workflow's existing service account is already used for
  `compute.instances.list` by the provision step, but
  `compute.instances.getSerialPortOutput` is a distinct permission. Whether the
  account holds it has to be confirmed by someone authorized to inspect that
  project's IAM. The step degrades to a `permission_denied` outcome if it does
  not, so a wrong guess is not destructive, merely useless.
- **Cloud use.** Turning the switch on means the job starts making cloud reads
  it does not make today.

No credential mount, role, binding or interactive access is added by this
change, and none should be added to enable it.

## Why the step still exits 0 on every path

The workflow marks this step `best_effort`, but in ci-operator that flag is
only honoured when the test also sets `allow_best_effort_post_steps`. The
ref's `optional_on_success` is paired the same way with the test's
`allow_skip_on_success`. The two OSD GCP jobs set neither, so both flags are
inert for them today, exactly as they already are for the other post steps in
this workflow.
Cleanup does not depend on either: ci-operator clears its short-circuit flag
before the post phase, so a failing post step does not stop the ones after it,
and this step additionally exits 0 on every path. Deprovision runs regardless.

Because `optional_on_success` is inert here, the step also runs on successful
jobs. That is intentional: a worker can be created and never join while the
cluster is still reported ready.

## Scope and identity

The cluster name is read only from `SHARED_DIR/cluster-name`.
`osd-ccs-cluster-provision-gcp` writes that file only once `ocm create cluster`
has returned successfully; because that script runs under `set -o errexit`, any
earlier failure exits before the write and leaves the file absent. The file is
therefore present for the case this step exists to observe, a cluster that was
created but never became ready, and absent when provisioning failed before the
cluster existed at all, where there is nothing to collect.

A missing, symlinked, multi-valued or malformed value fails closed with an
`identity_*` outcome. There is no project-wide scan, no fallback discovery and
no caller-supplied project or instance input; the project id comes from the
profile credential already in use.

The server-side name filter is not treated as a trust boundary. Every listed
instance is re-verified to start with this run's cluster-name prefix, to be a
syntactically valid instance name, and to sit in a syntactically valid zone.
Out-of-scope entries are counted and skipped.

## Output and confidentiality

These jobs publish to a world-readable bucket, and Prow's secret censoring only
covers values of secrets mounted into the pod. It would not redact material
generated at boot. Serial output is therefore treated as hostile input: it is
written only to a private `0700` scratch directory outside `ARTIFACT_DIR` and
`SHARED_DIR`, each file `0600`, removed on exit and on `HUP`/`INT`/`TERM`.

Everything published is drawn from a fixed vocabulary defined in the script:
per-unit status enums, marker counts, line and character counts, instance state
enums and error-class enums. Serial text, command stdout/stderr, instance names,
zones and project identifiers are never written to an artifact and never
printed. Per-instance records are keyed by ordinal index, not by name.

Serial output is also bounded while being read, because a capture may contain
no newline at all: at most 4 MiB is consumed per instance, each line is capped
before matching, matching uses substring tests rather than backtracking
regular expressions, and the parser re-checks the step's overall deadline.

## Reading the result

`collection-outcome.json` always exists and always carries an explicit outcome,
so "nothing collected" is distinguishable from "nothing wrong".

- `collector`: `disabled`, `complete` or `incomplete`.
- `reason`: `opt_in_required`, `collected`, `no_instances_in_scope`, an
  `identity_*`, `credential_*`, `auth_*` or `discovery_*` value,
  `budget_exhausted`, `scratch_unavailable`, `interrupted`,
  `tooling_unavailable` or `collector_error`. A provisional `interrupted`
  document is written before any cloud read, so the outcome still exists if
  the step is killed.
- per instance `collection`: `ok`, `no_signal`, `timeout`, `unavailable`,
  `permission_denied`, `not_found`, `unauthenticated`, `quota_exceeded` or
  `error`.
- per unit `status`: `failed_signal_observed`, `started_signal_observed`,
  `start_attempt_observed` or `no_signal`.

**Unit values are observed serial-log signals, not authoritative current
systemd state.** `no_signal` means the signal was not observed in the captured
output; it never means the unit is healthy, and the capture may be truncated or
may predate the interesting moment. A `failed_signal_observed` value is one
observation. It does not establish that the unit is the reason the instance
failed to join, and this step does not determine an underlying cause.
