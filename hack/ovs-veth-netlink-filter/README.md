# OVS veth netlink filter CI experiment

This directory contains the temporary BPF LSM experiment used by the optional
`aws-5.0-nightly-x86-cudn-density-single-ns-1000-24nodes-bpf` job. It is diagnostic
code and is not intended for production deployment.

The pre-test step clones the repository and ref configured by
`OVS_VETH_FILTER_REPO` and `OVS_VETH_FILTER_REF`, builds this directory with an
OpenShift binary Docker build, grants a dedicated service account the
`privileged` SCC, and rolls the DaemonSet out after the worker pool is scaled.
The regular 1,000-CUDN workload then runs unchanged.

The BPF program selects only the ovs-vswitchd `NETLINK_ROUTE` socket subscribed
to `RTNLGRP_LINK`. It drops well-formed `RTM_NEWLINK` and `RTM_DELLINK`
notifications only when every message in the skb describes a veth. All parse
errors and non-veth messages fail open. This also hides those veth events from
the OVS interface notifier sharing that socket, so pod networking health must
be checked alongside CPU and route-table dump counts.

Kubernetes readiness requires the current OVS target entry and pinned BPF link;
if OVS disappears or its socket cannot be rediscovered, the entrypoint removes
the readiness marker and the pod becomes NotReady until filtering is restored.

The post-test step saves these artifacts before cluster teardown:

- per-node BPF map counters (`bpf-stats-*.json`): target skbs at key 0,
  dropped veth skbs at key 1, aggregate parse failures at key 2, paged skbs
  at key 3, short link-kind attributes at key 4, batch overflows at key 5,
  kernel read failures at key 6, and mixed/non-veth batches at key 7;
- per-node OVS coverage before and after the CUDN workload;
- bounded `ovs-vswitchd` perf recordings, metadata, logs, compact symbol
  reports, and compressed symbolized callchains from four zone-spread workers
  (`ovs-perf-*`);
- DaemonSet resources and logs;
- the Network ClusterOperator state.

A useful run has nonzero dropped counts, reason-specific counters explaining
every significant fail-open population, normal pod/OVN health, and fewer
`route_table_dump` increments than the unfiltered baseline. The DaemonSet
termination trap removes its map entry and pinned BPF link; the post-test step
then removes the SCC grant and namespace.

The branch named by `OVS_VETH_FILTER_REF` must be pushed before requesting the
CI rehearsal, because the target cluster builds these assets from that ref.

The profiler sidecar uses the same privileged, host-PID DaemonSet as the BPF
filter. The deploy step chooses one worker per availability zone before filling
the remaining slots in node-name order. On those workers it records the host-
visible `ovs-vswitchd` with the software `cpu-clock` event at 19 Hz for at most
45 minutes. DWARF call graphs use a 2 KiB stack snapshot, which was sufficient
to resolve OVS and kernel netlink stacks in a loaded cluster rehearsal without
the much larger artifacts produced by the default 8 KiB snapshot. The gather
step interrupts any recording still active after an early workload failure,
waits for `perf.data` finalization, renders a compact report while the target
process namespace is available, and uploads the report, gzip-compressed
`perf script` output, and raw data. The symbolized script remains directly
usable with FlameGraph tooling after the short-lived cluster is gone.

## Live step rehearsal

On 2026-09-03 the deploy and gather command files were run directly against an
OpenShift `5.0.0-0.nightly-2026-08-31-084301` cluster. The test used the pushed
branch as its clone source and the same binary OpenShift build used by CI.

The rehearsal found and fixed two integration errors before submitting the CI
job: an ImageStream-trigger race was avoided by pinning the DaemonSet to the
new build digest, and OVS coverage collection was moved to the
`ovn-controller` container. The corrected deploy step completed successfully
on three workers, including image build, digest-pinned rollout, BPF attachment
checks, and baseline coverage collection.

Twenty probe pods were rolled to generate fresh veth events. The three worker
counters ended at `72/72/0`, `60/60/0`, and `22/22/0` for
target/dropped/parse-failure events. The exact gather step then produced BPF
JSON, before/after OVS coverage, DaemonSet logs and resources, and Network
ClusterOperator state. Cleanup was disabled for this rehearsal; its CI default
remains enabled. After collection the filter was `3/3` Ready, probes were
`20/20` Ready, and the Network ClusterOperator was Available and not Degraded.
