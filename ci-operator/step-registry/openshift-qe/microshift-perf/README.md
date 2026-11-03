# MicroShift Perf/Scale CI cycle

`/test perf-scale` is an optional presubmit on MicroShift `main` and
`release-4.22`, `release-5.0`, `release-5.1` and `release-5.2`. It reserves one Scale Lab R640 for the complete cycle. The
existing `/test perf-node-density` job retains its separate single-workload flow.
Do not run these jobs concurrently while the shared self-scheduling step has no
atomic free-cloud selection. No periodic is added. A periodic per supported
release branch would be useful for package baselines once the dependencies and
runtime have been qualified; that is a separate scheduling decision.

## Execution

The workflow initializes tools and optional indexing, stages the netperf runner,
self-schedules one host, and pings it. The chain then performs the existing full
`setup-node.yml` deployment and the complete iteration loop. Post steps remove
private ES handoffs and terminate the same QUADS assignment, including failures.

1. Fresh install, cold and warm startup captures. Iteration 1 is the full deploy;
   later iterations start at `Gather installed package facts`, the first static
   task in `install-microshift`, with repository and host preparation disabled.
   Subsequent logging roles still run and recreate the metrics service-account
   token. The skipped setup-localhost role only manages SSH known_hosts/key
   access and waits for SSH; it publishes no facts consumed by later roles.
   The first full deployment establishes those SSH prerequisites. The expected Ansible reboot remains part of each install.
2. Wait for the node, pods and MicroShift service to be ready. Check that node,
   process, crio, kubelet-microshift and kubelet-microshift-cadvisor targets all
   belong to the allocated node, are healthy, and have current `up == 1` values.
3. Cold idle window, then native `kube-burner-ocp index` with a profile file and
   5s query step. This is cold in the sense that no benchmark workload has run;
   the Ansible cold/warm startup captures have already completed.
4. `node-density` QPS sweep, followed by `node-density-cni`: QPS 2, 4, 6, 8, 10,
   12, 14, 16, 18, 20, burst equal to QPS, 245 pods/node target, MicroShift-safe
   metadata and no alerting. Each point has its own UUID and local directory.
5. Settle, then `network-perf-v2/full-run.yaml`, using MicroShift local/single-node
   mode and bastion Prometheus. The standalone netperf ref can also run once
   after perf-init and deploy; stage-only mode stages that same runner for reuse.
6. Wait for readiness and collect the warm idle window with native indexing.
7. Collect an iteration bundle and checksum before the next fresh install.

Prometheus preflight runs before both windows, again at each window's end, and
before each sweep and network workload. It rejects missing jobs and stale-host
scrape configuration rather than accepting an empty result. A successfully
started MicroShift is also checked after every fresh install. PR source builds
remain fixed at the initial `PULL_PULL_SHA`; each reinstall checks binary
`gitCommit` again. The current automation has no install-existing-built-RPM input,
so each source-mode iteration rebuilds from that SHA. Per-iteration host snapshots
record installed RPM NVRs and the MicroShift binary SHA256; builds are not assumed
bit-for-bit identical. Package baselines should specify an exact version/RC. Automation is the single checkout created by deploy.

A failed QPS point or cleanup invalidates the entire iteration. No later workload
runs in that iteration. Its partial logs/metrics and a debug bundle are retained;
the next iteration starts with a fresh install if there is enough budget. The
job remains failed even if subsequent iterations succeed. These are collection
attempts, not automatically accepted report datapoints. Consistency thresholds,
outlier decisions, automatic extra iterations and report generation belong to
`microshift-perf-tools`; this job collects the configured number (default 3,
maximum 5) without silently selecting a passing subset.

## Parameters

All time values below are integer seconds. Ref YAML documents every parameter.

| Parameter | Default | Purpose |
| --- | --- | --- |
| ITERATIONS | 3 | Fresh-install attempts, 1..5 |
| COLD_WINDOW / WARM_WINDOW | 1800 / 1800 | Idle measurement windows |
| SETTLE_SECONDS | 600 | Before pod-network tests |
| CYCLE_BUDGET_SECONDS | 115200 | 32h total, including provisioning |
| MIN_ITERATION_BUDGET_SECONDS | 21600 | Require 6h remaining before starting an iteration |
| E2E_REPO / E2E_VERSION | upstream / master | Branch head resolved once; explicit fork/branch/tag/commit overrides supported |
| KUBE_BURNER_VERSION | latest | Latest public release resolved once at init; explicit versions/tags are pins |
| METRICS_PROFILE_REPO / METRICS_PROFILE_REVISION | upstream / main | Branch head resolved once; explicit tags/commits remain pins |
| NETPERF_VERSION | latest | Latest public release resolved once at init; wrapper receives the concrete tag |
| NETPERF_TIMEOUT_SECONDS | 7200 | Full network workload bound |
| SWEEP_SLEEP / SWEEP_CLEANUP_TIMEOUT | 30 / 300 | Upstream QPS sweep controls |
| PERF_RC | PR SHA or configured version | Explicit release/RC label override |
| PERF_ES_URL | secret host | HTTPS endpoint without inline credentials |
| PERF_ES_INDEX | microshift-perf-v1 | Dedicated Ansible measurements index |
| KUBE_BURNER_ES_INDEX | ripsaw-kube-burner | Optional native kube-burner metrics index |

Default tool pointers move between jobs so merged upstream changes need no CI PR.
Init resolves E2E master and metrics-profile main to exact commits. For each binary
set to latest, it makes one TLS-verified HEAD request to
`https://github.com/<repo>/releases/latest` (5s connect timeout, 20s total, 25s
outer deadline plus 2s kill-after). It does not follow redirects: the final HTTP
response must be a redirect with exactly one Location containing the same HTTPS
github.com repository and a validated `/releases/tag/<tag>` path. Missing releases,
unexpected hosts/paths, malformed tags or HTTP failures stop init before reservation.
Concrete version/tag values bypass the request and remain explicit pins.

Python >= 3.9 is the supported minimum. Init checks the available python3 version
before creating the cycle identity, fetching tools, probing ES or reserving hardware.

Init records the requested refs/versions, resolved commit SHAs, concrete release
tags and kube-burner archive/binary SHA256 in tools.json. Every consumer uses that
handoff, including cached prepare_tools calls; none re-resolves latest mid-cycle.
The network wrapper receives a concrete tag such as v0.1.43, matching its release
URL construction. Per-run netperf binary hashes are archived and all observed
hashes and concrete release tags are recorded in cycle.json. A moving default
can change behavior between jobs; inspect the recorded versions when comparing
runs. It does not change the tool identities halfway through a cycle.

The presubmit timeout is 36h and the cycle ref timeout 33h, leaving post cleanup
and termination time around the 32h work budget. Diagnostics and artifact
collection can extend beyond that budget; the 36h job limit is separate. Individual reinstall and
sweep invocations are bounded to 2h. The package-mode estimate is roughly
4.2-5.3h; source builds can add time to every iteration; hardware availability and actual full-run runtime need qualification.
When no matching host is available, self-sched fails before creating any assignment.
Post cleanup removes the private handoffs; the shared terminate step currently logs
in and then fails on the missing assignment_id, without issuing a terminate request.
It still needs a shared-step early no-assignment exit to make that path a clean no-op.
The shared self-sched validation wait is not bounded internally on this base;
the job timeout provides the outer bound. Its allocation race and incomplete
assignment-id handoff are shared-step follow-up work, not hidden here.

## ES and secrets

Initialization uses the existing `ocp-perfscale-cpt/ocp-qe-perfscale-es-creds`
collection. It makes one bulk request under a 20s wall-clock deadline (5s socket
timeout), with TLS verification, no redirects and no retries. A create receipt
with `metricName=microshiftPerfCIProbe` and a cycle UUID verifies only the dedicated
Ansible destination. The job never writes probe documents into native tool indexes.
Native destinations retain their own tool upload/error handling. The receipt
is CI capability evidence, not benchmark results. The probe does not configure
mappings or retention. Any missing credential, unavailable endpoint or rejected
item selects local-only operation and prints that decision.

Local indexing is always enabled. Sweeps use the native metrics-endpoint list
with a 5s step and separate local/optional ES indexers; the endpoint template
`collected-metrics-{{.UUID}}` is rendered from the UUID exported by each upstream
sweep point, giving it its own directory. The wrapper's
separate metadata indexing is disabled for sweeps so credentials stay in the
private endpoint file. Windows run mandatory local indexing first, then an
optional native ES invocation. This avoids the native `index` command choosing
one summary indexer when multiple are configured. If that optional window upload
fails, later uploads are disabled and local collection continues. Other native
tools still decide whether an upload failure is a workload failure; a resulting
nonzero sweep exit invalidates its iteration. Local artifacts remain available.

Netperf follows the existing openshift-qe-network-perf step: when the init probe
succeeds, ES_SERVER carries the credentials from ocp-qe-perfscale-es-creds into
network-perf-v2/run.sh. Native k8s-netperf upload and wrapper metadata ES indexing
are enabled, with their defaults (native k8s-netperf, metadata perf_scale_ci).
No configurable netperf index is advertised or passed. When the probe fails,
ES_SERVER is empty and both uploads stay disabled; local CSV/JSON results,
metadata files and redacted logs are always retained.

This deliberately matches the upstream transport behavior. k8s-netperf v0.1.43
hardcodes InsecureSkipVerify: true in pkg/archive/archive.go and does not verify
TLS. The wrapper metadata helper also uses its upstream insecure curl path.
The verified init probe does not change those clients' TLS behavior. Tracing
stays off, and wrapper/native output and copied partial results pass through
redaction before reaching Prow logs or artifacts.

The previously qualified native v1.12.7 `index` queries to `end + 600s`. The job invokes it immediately
after the idle window and completes indexing before starting the next workload;
the future query interval therefore contains no subsequent benchmark workload.
The actual window epochs and the pinned tool revision are archived. This native
extension must be considered when validating steady-state coverage. With the
moving latest default, verify the behavior of the recorded concrete release;
this note does not assert every future release has the same query extension.

Credentials/derived URLs have tracing disabled. Private shared handoffs and
remote files use restricted permissions, stay outside results directories, and
are removed on normal and post cleanup paths. Native tool output is redacted
before entering artifacts or Prow logs. Do not archive private endpoint files,
ES URLs, kubeconfigs, or environment dumps. A job that cannot obtain the secret
mount at all cannot start; optional indexing describes missing credential files
or denied writes after pod scheduling, as with other credential-backed CI steps.

## Artifacts and dependencies

Each iteration has `iteration-N/` with `ansible/` text plus
`measurements.ndjson`, `window-cold.json`, `window-warm.json`, profile-indexed
`collected-metrics-*` directories, QPS `sweep-*.json`/logs, `netperf/` CSVs and
logs, stage-specific Prometheus targets/up snapshots, service journal, events,
pod logs and pod/host snapshots, and `status.json`. A tarball and SHA256 accompany it.
Initialization archives exact tool revisions, the kube-burner binary hash,
profile, and sanitized ES status. Only small, flat prefixed handoff files enter
SHARED_DIR (under the 1MiB aggregate Secret limit). Tool checkouts/binaries stay
in the step's local /tmp; the consuming step fetches the recorded commits and
checks both archive and binary hashes again. Every QPS point uses that verified
archive through KUBE_BURNER_URL=file:// with a private KUBE_DIR, so the recorded
binary hash covers windows and both sweeps. The netperf runner and library are small flat files,
not directories. Tests enforce this propagation model between step executions. Netperf archives its downloaded binary hash.
Window records are written atomically with jq 1.6-compatible variable names; a
writer failure stops that iteration before indexing or workloads. The manifest
writer tolerates malformed partial artifacts, records artifact_errors and writes
an atomic incomplete cycle.json instead of losing the diagnostic manifest.
An absent structured Ansible archive invalidates the iteration. A failed Ansible
reinstall (iteration 2 onward), including a ready.sh startup failure, retains
`stage=install` and Ansible's exit code even if structured measurements are absent.
Its partial diagnostics are collected; later workloads in that iteration are skipped,
and later iterations can run if the budget allows, while the job remains failed.
The initial full install is a separate deploy step: if Ansible fails there, the cycle
step never starts. Deploy diagnostics and post cleanup remain available, but no
iteration-1 status or root cycle.json is produced by the skipped cycle step.

Merge/qualification dependencies:

- USHIFT-7441 / release #83408 supplies authenticated QUADS inventory, host prep,
  source builds, service gating and cleanup. This worktree is based on it.
- Until cloud-bulldozer/e2e-benchmarking#875 merges, upstream master lacks
  sweep.sh and the default init stops before reservation. Meanwhile a run can
  set E2E_REPO/E2E_VERSION to the PR's fork/head commit. After merge, the default
  master pointer picks up sweep support automatically; no new CI PR is required.
- MicroShift structured measurements/ES indexing must merge into the automation
  revision selected by MICROSHIFT_BRANCH (or MICROSHIFT_PR for a package-mode
  dependency qualification). No local Ansible fork is embedded in this flow.
- The per-component microshift-metrics.yml change must merge into main. The
  default profile pointer then picks it up automatically. A fork/revision override
  remains available beforehand; the older profile captures raw processes and is
  insufficient for the final report.
- This worktree is based on signed #83408 commit `50285169e14`, including the
  owner-based terminate fix #86450 and node-density jobs on all five branches.
- release-5.2 currently derives stream 5.1 from its PR version file. Once it bumps
  to 5.2, main's automation needs a measured 5.2 pod-count entry in
  `ansible/vars/microshift_versions.yml` and qualified 5.2 source-build dependencies.
  The CI branch name alone does not select the product stream.

Local verification (no ES/lab/CI contact): run `python3 hack/tests/test_microshift_perf_cycle.py` from the repository root,
ShellCheck and bash syntax checks; regenerate registry metadata, scoped MicroShift
Prow jobs and sanitization; run ci-operator-checkconfig against the five changed
configs and full registry. A passing fake test suite is not live qualification.

The cycle ref writes root `cycle.json` for the perf-tools report consumer. It
records string iteration IDs and paths, capture status, release/RC, environment,
tool pins/hashes, the expected matrix, actual per-QPS workload UUIDs/QPS/burst,
window UUIDs/epochs and all-pods-Ready attestations, netperf UUIDs, and upstream
sweep results. Incomplete/budget-exhausted/interrupted cycles retain an incomplete
manifest. After all requested captures and bundles complete, optional ES mode
publishes `measurement_type=report_cycle`, `status=complete` in PERF_ES_INDEX,
using cycle_id as the document ID under a 20s deadline. Marker upload failure
leaves the local manifest available. This marker attests collection completion;
perf-tools still checks at least three valid iterations and actual metric/matrix
coverage before accepting a report. No completed marker is published for an
invalid iteration or an incomplete requested cycle.

One- or two-iteration smoke runs are supported by ITERATIONS. Their capture may
finish successfully, but the report acceptance contract still requires at least
three valid iterations; an incomplete/insufficient report verdict on a smoke
run is expected.

Init records the self-scheduled MODEL once, lowercased, as the hardware class
(`R640` -> `r640`) with `platform: BareMetal`, the go-commons value other
perf-scale indexes use. Both are passed to every Ansible install as
`perf_hardware`/`perf_platform`, so each measurement carries them, and they
appear on the write probe and at the top level and in `environment` of the
cycle manifest. An explicitly selected alternative model is therefore not
mislabeled `r640`. Nothing is inferred from the CPU model.

Per-iteration failure collection includes bounded MicroShift/CRI-O journals,
pod container logs (system namespaces first), events, pod state, disk space, RPM identities and binary
hash. Its network groups are bounded to 60s for result copy, 30s for journals,
10s each for events/pods/host state, and 20s for pod logs, with a 30s archive
bound and 5s kill-after; those bounds leave room under the 5m cycle grace period for
signal handling. On interruption the cycle allows the workload group up to 25s
plus a 2s kill-after to finish netperf cleanup; completion-marker upload is skipped
for incomplete cycles. Netperf stops its own child group, then spends at most 20s
plus a 2s kill-after archiving/redacting partial CSV/JSON/log files before removing
its own standalone work directory. In a cycle, the caller retains the private work
directory and the collector can recover its partial files under the same 20s plus
2s bound even if the runner exit trap was interrupted. This fallback also stops
the recorded native process group. The 5m cycle grace period covers the added
recovery work; interrupted-cycle tests check the CSV inside the iteration tarball. Snapshots may be partial
when a host or API is unavailable.

The local suite includes unmodified upstream wrapper fixtures at e2e-benchmarking
commit 449056e2083614240e886c19a956dfb1f002a21d (source hashes in
hack/tests/fixtures/e2e-benchmarking/source.json). Downloads, binaries and cluster
commands are faked; the actual wrappers and metadata helper execute. For jq 1.6
qualification, set `JQ16=/path/to/jq-1.6/bin/jq` to enable the optional compatibility
test. To qualify the whole suite on 1.6, also prepend its directory to PATH:
`JQ16=/path/to/jq-1.6/bin/jq PATH=/path/to/jq-1.6/bin:$PATH python3 hack/tests/test_microshift_perf_cycle.py`.
The reserved jq variable guard runs even when JQ16 is unset. Generation order is make ci-operator-config, scoped
prowgen, sanitizer, then registry-metadata; run both config validators afterwards.
