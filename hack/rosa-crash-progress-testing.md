# ROSA operator crash progress regressions

Run `python3 hack/test_rosa_crash_progress.py` from the repository root.
The standard-library unittest harness runs the actual operator readiness script
with synthetic `oc`, `date`, and `sleep` executables. It needs Bash, jq, and GNU
timeout; it does not use cluster credentials or make network requests.

An unchanged set of affected operator names does not establish unchanged pod
restart activity. Crash observations compare sorted pod UIDs, container names,
container IDs, restart counts, and last termination timestamps. Failed or
incomplete pod observations interrupt consecutive stationary evidence. Two
identical complete crash observations still fail early. Restart activity never
satisfies an operator condition, extends a phase deadline, or resets the
existing operator-set stall timer.

Crash diagnostics use the same observation before the next poll can replace
the failing pod. Per phase, collection is limited to 40 cumulative seconds,
eight captures, four failing containers per capture, and ten warning events.
Each command has a five-second maximum bounded by the phase/collection deadline;
GNU timeout can take an additional second to kill an unresponsive process.
Events are collected before logs, and previous logs before current logs, so
slow log requests cannot starve event collection. The budget remains available
for crashes first observed later in the phase. Pod queries are bounded to ten
seconds (or the remaining readiness time) and 1 MiB. Diagnostic event responses
are capped at 1 MiB before projecting fields. Log requests use 100 lines and
16 KiB; retained files are capped at 16 KiB for logs and 64 KiB for status/events.
Paths `crash-<condition>-<iteration>-<capture>/` are deterministic and unique
within a script execution. Capture failures are best effort, never readiness
evidence.

Each `status.json` entry links its `index` to the corresponding
`container-<index>-{previous,current}.log` files, with operator, inferred namespace,
pod name, pod UID and container name. These selected identities are length-bounded
and restricted to Kubernetes identifier characters; invalid values are omitted.
No labels, annotations, arbitrary identifiers from log bodies, or specs are kept.
Events are namespace-wide warnings, not necessarily events for the selected pod.

Raw log bodies can contain credentials. Current and previous log artifacts
therefore retain only line numbers and fixed panic/fatal-error/segmentation-fault
signatures; all other text is omitted, rather than relying on incomplete secret
redaction patterns. Status retains restart counts, validated termination times, numeric termination fields,
and an OOM flag; events retain allowlisted reasons and numeric counts. No raw
specs, messages, credentials, or API stderr are saved by the new collector.
This deliberately limits root-cause diagnosis; restarting alone does not prove
health or explain a console crash. Fixed signatures and numeric fields cannot
guarantee root-cause completeness, and a pod may disappear between observation
and log retrieval. Existing general operator diagnostics are
unchanged.

The registry ref invokes the edited commands directly using `rosa-aws-cli`.
`hack/validate-registry-commands.sh` applies `shellcheck -S warning` to registry
scripts. The Makefile also exposes containerized `python-validation` (pylint
with `hack/.pylintrc`) and `validate-step-registry` (YAML/registry resolution).
No registry definitions or generated configuration change in this patch, so
focused shellcheck, Bash syntax, pylint, unittest, and clean-diff checks cover
the changed consumer path without generating or triggering CI jobs.
The regression suite is manual: no current Prow job or Makefile target invokes
`test_rosa_crash_progress.py`. Existing step-registry shellcheck and hack Python
lint jobs cover syntax/security rules and pylint respectively, not these runtime
regressions. Local focused checks do not establish that full CI has passed.

The `ci/rosa-aws-cli:latest` build is declared by
`ci-operator/config/openshift/rosa/openshift-rosa-master__images.yaml`, using
`openshift/rosa`'s `images/Dockerfile.e2e`. That Dockerfile installs jq and verifies
the OpenShift client. Bash, GNU coreutils (including timeout/head/date), and awk
are runtime base-image tools; verify the resolved image rather than assuming a
particular RPM package name (coreutils may be provided by coreutils-single).
