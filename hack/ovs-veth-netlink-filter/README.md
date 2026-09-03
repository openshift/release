# OVS veth netlink filter CI experiment

This directory contains the temporary BPF LSM experiment used by the optional
`aws-5.0-nightly-x86-cudn-incremental-1000-24nodes-bpf` job. It is diagnostic
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

The post-test step saves these artifacts before cluster teardown:

- per-node BPF map counters (`bpf-stats-*.json`): target messages at key 0,
  dropped veth messages at key 1, and parse failures at key 2;
- per-node OVS coverage before and after the CUDN workload;
- DaemonSet resources and logs;
- the Network ClusterOperator state.

Healthy filtering has equal target and dropped counts, zero parse failures,
normal pod/OVN health, and fewer `route_table_dump` increments than the
unfiltered baseline. The DaemonSet termination trap removes its map entry and
pinned BPF link; the post-test step then removes the SCC grant and namespace.

The branch named by `OVS_VETH_FILTER_REF` must be pushed before requesting the
CI rehearsal, because the target cluster builds these assets from that ref.
