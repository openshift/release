# HO upgrade minimum diagnostics

The `rosa-e2e-hcp-ho-upgrade` workflow enables `HO_MINIMAL_DIAGNOSTICS`.
The shared test/deploy/verification refs default it to false. Their existing
commands, readiness assertions, exit status and TERM child cleanup remain in
place. Full must-gather, gather-extra, HCP CR status collection, deprovisioning
and HO restoration remain separate. No best-effort-post flag or existing
full-gather failure accounting is changed.

## Execution and targeting

An EXIT hook in each already-running test/deploy/verification container calls
the minimum collector before returning the original status, including when the
first e2e test fails and short-circuits the remaining test steps. The first post
ref also calls it as a fallback before deprovisioning; its collection failures
are reported in artifacts without making a new test assertion. This is not a
retry of a pod that never started.

After obtaining the existing MC kubeconfig, deploy also captures the same safe
schema before the lock/image checks or any image mutation. Its artifact is
`ho-before-deploy/ho-minimal-diagnostics.json`, with phase `before_deploy`.
The ordinary deploy EXIT artifact has phase `deploy`, even for a skipped or
failed deployment; neither snapshot proves an upgrade occurred. This replaces
the former unrestricted HC/NP capture, not an additional raw-data collector.
The baseline has its own 60-second deadline; deploy can spend at most two such
collection windows (plus kill grace), while its EXIT collection alone delays
teardown by at most one window. Baseline helper failure cannot block deploy;
the EXIT hook still attempts collection and reports missing-helper failure.

The refs use `run_as_script`. ci-tools constructs a per-test immutable command
ConfigMap containing the resolved pre/test/post scripts and mounts it in each
such container at `/var/run/configmaps/ci.openshift.io/multi-stage`. The hook
uses the sibling key `rosa-hypershift-operator-gather-minimal`, not a file from
the image or a new preparatory pod. The script derives the directory from its
own `BASH_SOURCE`; a missing key produces a failure manifest. Consumer source:
[init.go](https://github.com/openshift/ci-tools/blob/eb04b51e34d3d97ec84f7e34e6984b24fd206261/pkg/steps/multi_stage/init.go#L172),
[gen.go](https://github.com/openshift/ci-tools/blob/eb04b51e34d3d97ec84f7e34e6984b24fd206261/pkg/steps/multi_stage/gen.go#L255).

The collector reuses `SHARED_DIR/hs-mc.kubeconfig`, provisioned by the existing
management-credentials step. It does not acquire credentials, download tools,
log in or elevate access. The CI cluster ID/name handoffs and OCM environment
identify the expected workload namespace, following the existing
`rosa-cluster-wait-ready-external-oidc` convention:
`ocm-<environment>-<cluster-id>-<cluster-name>` (`integration` maps to `int`).

A bounded HCP lookup in that namespace reads the
`hypershift.openshift.io/cluster` annotation to obtain the **distinct** HC
namespace/name. The HC must exist, its clusterID must match the HCP, its name
must match the CI handoff, and HyperShift's HC-to-workload-namespace function
must reproduce the expected workload namespace. Ambiguous, paginated or
unmatched discovery fails closed. NodePools are filtered by HC namespace and
clusterName; there is no all-namespace fallback.

Public HyperShift contracts:
- [HCP-to-HC annotation](https://github.com/openshift/hypershift/blob/362e38cbec7d5d66908dd9a5d333b9d85f2cd577/support/k8sutil/constants.go#L7)
- [Workload namespace derivation](https://github.com/openshift/hypershift/blob/362e38cbec7d5d66908dd9a5d333b9d85f2cd577/pkg/manifests/manifests.go#L10)
- [Management-side catalog component](https://github.com/openshift/hypershift/blob/362e38cbec7d5d66908dd9a5d333b9d85f2cd577/control-plane-operator/controllers/hostedcontrolplane/v2/olm/catalogs/component.go#L10)

The primary catalog evidence is the **management-side**
`redhat-operators-catalog` deployment in the validated HCP workload namespace,
not the guest catalog ClusterOperator. The fixed `hypershift/operator`
deployment is collected independently. For each deployment, label-selected
ReplicaSets must have its controller UID, and pods must have a selected
ReplicaSet's controller UID. Events are queried for at most two selected pod
UIDs and verified again after retrieval. Identifiers/selectors are used only
in memory and API requests, never retained in the bundle. A missing deployment
or no selected pods is not a complete collection. A sector-selected MC that
does not contain the CI target yields partial/unavailable data, not a wider
discovery query.

## Bounds and public schema

Each invocation has a 60-second wall deadline with a two-second kill grace.
Each request has a three-second API timeout, four-second process timeout and
one-second kill grace. There are at most 18 requests, with one-page raw API
list limits (no automatic pagination), at most 1 MiB per response, a 128 MiB
virtual-memory limit per jq parser and ten CPU seconds per collector process/child.
The parser memory limit is not applied to the Go-based oc process, whose virtual
address-space reservations exceed that bound. Core dumps are disabled.
The final artifact is at most 256 KiB. All limits are fixed, not job inputs.

`ho-minimal-diagnostics.json` is written atomically in the invoking step's own
`ARTIFACT_DIR`; no raw intermediate files are written. Each category has an
outcome, items and a truncation flag. Overall complete requires every category
complete and untruncated; otherwise it is partial. Fatal collection/tool/helper
failures produce a small failed manifest. An unwritable artifact directory
cannot hold even a failure manifest; collection remains non-blocking and emits
only a static warning when possible. API errors and inherited diagnostic xtrace
are suppressed, not copied into artifacts.

The structured allowlist contains:
- HC/HCP/target NodePool generation and finite condition types/statuses,
  observed generation and validated transition timestamps (16 conditions,
  eight NodePools maximum).
- Deployment desired/current/updated/ready/available/unavailable replica counts
  and generation/observedGeneration. Missing numeric values remain null rather
  than becoming zero. Related ReplicaSets retain corresponding available counts
  (eight maximum); fields unsupported by that resource remain null.
- Up to eight related pods per role: finite phase, node-assignment boolean,
  PodScheduled status, readiness/restarts, current and last container state,
  exit code/signal, known reason enums and validated timestamps. Init and regular
  container statuses are capped at four each; no container identities persist.
- Up to eight events for each of two selected pods per role: finite type/reason,
  counts and validated timestamps only. Owner relationships are validated during
  selection, not retained as raw UIDs.

Unknown reason/status values map to `Other`; unknown condition types are omitted.
No raw names, namespaces, node identifiers, UIDs, labels, annotations, image
references, specs, messages, credentials, API errors or log text are retained.
Logs are explicitly `omitted_by_policy`: current/previous raw log text has no
newly approved safe retention contract. OCM is explicitly `not_queried`; even
an authenticated lifecycle lookup would add a dependency/latency surface and is
not necessary for this minimum mitigation. Guest ClusterOperator diagnostics
remain in existing full gather, not duplicated here.

## Guarantees and limits

The original step's own Prow sidecar can upload these artifacts even when its
test entrypoint fails. Upload does not require a later gather pod to start.
This does not guarantee upload: original pod startup failure, SIGKILL/OOM/node
loss, sidecar/storage failure, denied API access or invalid target handoffs can
still prevent collection. It is a completion snapshot, not continuous durable
upload or full root-cause coverage. Before/after comparisons use the same
scoped, sanitized schema; the previous raw HC/NP identity/message files and
their harness are removed. Existing readiness queries remain unchanged;
the new diagnostic API requests never use an all-namespace fallback.
General startup retries or guaranteed node separation require ci-tools/Prow
changes; a local shell cannot reschedule its own unstarted pod.

## Offline checks

Run `python3 hack/test_rosa_ho_minimal_diagnostics.py`. The suite executes the
registered scripts with synthetic API/CLI fixtures and the actual mounted-key
layout, without cloud/cluster access. It covers early artifacts, exit status,
management-side catalog ownership and namespace separation, bounded failures,
schema allowlisting, truncation and TERM cleanup. Existing original step logs
are unchanged; tests specifically ensure new diagnostic payloads do not leak.

Use `make registry-metadata` to generate metadata, then the repository's registry
validation and shellcheck consumers. Do not hand-edit generated metadata/jobs.
