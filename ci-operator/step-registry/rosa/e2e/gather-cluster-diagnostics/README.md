# Bounded pre-install observations

The delivered commands file is self-contained: ci-operator delivers that file,
not adjacent repository files. The Python collector is embedded in the Bash step.
Run offline regression tests from the repository root:

```sh
make test-rosa-gather-diagnostics
python3 -m unittest discover -s hack -p 'test_rosa_ocm_fvt_artifacts.py' -v
shellcheck -e SC1091 ci-operator/step-registry/rosa/e2e/gather-cluster-diagnostics/*commands.sh
```

## Identity and ordering

The FVT wrapper mounts its output into the nested test container, not SHARED_DIR.
After the test returns, the wrapper publishes a bounded, run-bound name manifest
and immutable-ID manifest from the original profile recordings, before the
existing ID/kubeconfig handoff.
The original test exit and EXIT cleanup remain authoritative. The collector does
not change teardown or enable deferred cleanup. If nested teardown has already
deleted a cluster or its recording, observations may be unavailable. A completely
empty shared directory cannot safely identify a cluster; it yields an explicit
collection outcome, never an environment-wide scan.

Existing shared IDs must identify exactly one cluster. Name recovery requires
the producer manifest's job and build to match this run, exactly one validated
name, exactly one exact-name CMS search result (page size two, total one), matching
immutable recorded ID, and creation within the recorded test window. All recorded
IDs/names must be unambiguous and agree with legacy shared IDs. Name/time alone
cannot establish ownership: name-only recovery without an immutable association
is explicitly unsupported. Prefix-only, stale, replacement, malformed and
ambiguous matches are rejected. Missing recordings require an earlier producer
handoff before nested teardown; the collector does not guess from arbitrary logs.

Standalone immutable IDs retain the existing workflow trust boundary, not a
claim that ID syntax or a namespace name proves ownership. ci-operator deletes
and recreates the multistage shared Secret before execution; each serialized
step receives its contents and publishes its resulting writable shared directory
before the next step. See `openshift/ci-tools` at
[`f6a3775`, shared initialization](https://github.com/openshift/ci-tools/blob/f6a37750355c09d581419b03ef9690b2d7e4021a/pkg/steps/multi_stage/init.go#L49),
[step sequencing](https://github.com/openshift/ci-tools/blob/f6a37750355c09d581419b03ef9690b2d7e4021a/pkg/steps/multi_stage/run.go#L84),
and [shared-state publication](https://github.com/openshift/ci-tools/blob/f6a37750355c09d581419b03ef9690b2d7e4021a/cmd/entrypoint-wrapper/main.go#L159).
The namespace is reusable: this association assumes trusted workflow producers
and no overlapping invocation of the same namespace/test pair. It is not a
certificate for arbitrary imported shared data or malicious preceding steps.
An absent manifest preserves existing single-ID collection. A present invalid,
empty or ambiguous manifest cannot be bypassed by a legacy ID.

The FVT handoff format is version 2: `started_ns` and `finished_ns` are integer
Unix epoch nanoseconds captured with `time.time_ns()`. The collector compares both
bounds exactly with RFC3339 creation times, including 1–9 fractional digits and
timezone offsets. Legacy unversioned second/float windows cannot recover their
discarded start precision and are rejected as `invalid_run_window`, without
falling back to a shared ID when such a manifest exists. Producer and collector
are delivered from the same job configuration; the standalone shared-ID path
without a manifest remains supported.

When a recording includes both an immutable ID and a name, the exact-name
cross-check is mandatory even if a legacy shared ID agrees. An unavailable,
timed-out, oversized or malformed lookup cannot establish that association, so
collection stops before all pre-install and guest requests with an explicit
`identity_lookup_*` outcome. Matching IDs never bypass contradictory or
unverifiable name evidence; a successful lookup with a different ID is rejected.
Only literal identity fields declared in bare recordings or `[Cluster]` sections
are accepted. Default options and interpolated identity are not ownership proof.

## Supported access and output

The existing OCM token authenticates reads of the documented CMS cluster,
`/status` and `/resources/live` endpoints. The public API contract is in
`openshift-online/ocm-api-model`, under `model/clusters_mgmt/v1/`:
`cluster_resource.model`, `cluster_status_type.model`, `resources_resource.model`
and `resource_type.model`. Permissions are not expanded. ProjectClaim and
ProjectReference status/condition enums and reference-presence fields follow the
public `openshift/gcp-project-operator` API types in `api/v1alpha1/`.

Only fixed states, condition types, boolean statuses and a boolean indication of
the fixed `ReconcileError` reason are published. Reference names, project IDs,
specs, messages, credentials and raw API responses are never published. Resources
not exposed by the existing CMS API produce an explicit unavailable/unsupported
outcome. Operator logs have **no predefined authorized path in this step** and
remain unsupported: there is no management-cluster login, elevation, cloud API
call or new credential. An error condition is an observation, not proof that the
condition is terminal or that it caused the test failure.

Only after pre-install reads does the collector attempt existing guest backplane
login and credentials-API fallback. Guest pod/operator statuses are allowlisted;
current/previous oauth-apiserver and etcd logs become fixed error/panic/timeout
counts, with bounded Normal/Warning event counts, not raw text. This deliberately
trades arbitrary log text for safe public
artifacts; full root-cause coverage is not claimed.

JSON depth failures invalidate only the affected response or resource, preserving
valid siblings and continuing safe collection. Rejected backplane archives are
never executed; they record `invalid_tool_archive` and use only the existing CMS
credentials fallback, recording `access_unavailable` if that also fails.

Each CLI operation has a 20-second limit (downloads 65 seconds), stdout is capped
at 1 MiB, downloads at 200 MiB, and the total command budget is 450 seconds within
the ref's ten-minute timeout. There are at most three pre-install reads, one name
lookup, four guest pods per namespace, and two log reads per pod. Private CLI
configuration, credentials and downloads live in a temporary directory removed
on completion. Tool extraction selects only the executable, with a 20-second
deadline, 200 MiB file limit and 128 MiB address-space limit; links are rejected.
Commands run in owned process groups; completion/timeout stops descendants and
reaps the direct child, so an extractor cannot leave decompression running.
Individual artifacts contain bounded summaries only. The bootstrap
outcome survives missing Python, tools, login or unexpected collector failures.

PendingProject alone never fails the test and this collector changes no wait
policy. Terminal-condition handling or a separately justified configurable
pre-install no-progress budget belongs in the tester's provisioning wait path,
not in this best-effort post step.
