# hypershift-etcd-perf

Runs one `kube-burner-ocp etcd-density` workload against a HyperShift hosted
cluster and measures the hosted control plane's etcd while it runs.

This exists to give etcd sharding a periodic measurement, as opposed to the
`e2e-*-etcd-sharding` jobs, which are functional: they assert that shards get
deployed, that the kube-apiserver is given the right `--etcd-servers-overrides`,
that keys land in the shard they are routed to, and that the shards survive a
restart. Those jobs deliberately measure nothing. This one produces numbers and
nothing else.

## Why a hosted cluster needs its own step

On a standalone cluster, kube-burner points at one cluster and finds etcd in
`openshift-etcd` on that same cluster. On a hosted cluster the two halves are on
different clusters: the load lands on the guest API server, but the etcd under
test is a set of pods in `clusters-<name>` on the management cluster.

So this step:

- drives the workload with `${SHARED_DIR}/nested_kubeconfig` (the guest),
- scrapes metrics from the management cluster's Thanos, via a metrics profile
  re-scoped from `namespace="openshift-etcd"` to `namespace="clusters-<name>"`,
- enables user workload monitoring on the management cluster first, because
  without it nothing scrapes the hosted control plane's ServiceMonitors at all,
- verifies that etcd series are actually arriving before starting the workload,
  so a job cannot burn hours producing load and no measurement.

The `kube-burner-ocp-wrapper` in `cloud-bulldozer/e2e-benchmarking` does have a
hosted-control-plane mode, but its AWS path is ROSA specific: it derives the
control plane namespace from the `api.openshift.com/name` resource tag and it
expects an Observability Operator route on the management cluster. Neither holds
on the HyperShift CI lanes, which is why this step talks to `kube-burner-ocp`
directly.

## Per-shard breakdown

Every etcd series in the profile keeps its `pod` label. With sharding enabled
the pod names carry the shard name (`etcd-0`, `etcd-events-0`, `etcd-leases-0`,
...), so `by (pod)` is a per-shard breakdown for free. The shard topology in
effect is also dumped to `hostedcluster-etcd-spec.json` and `etcd-pods.txt` in
the artifact directory.

## Comparing standard against sharded

The step does not compare topologies. It measures whichever hosted cluster it is
pointed at and records `shardingVariant` in the result metadata. A comparison is
two jobs on the same schedule running the same workload with the same flags,
where one creates the hosted cluster with `HYPERSHIFT_ETCD_SHARDS` set and the
other does not. With `INDEX_TO_ES: "true"` both land in the perf and scale
Elasticsearch and Orion can do the diffing; without it, the numbers are in the
artifact directory under `collected-metrics-<uuid>/`.

## Workloads

The four `etcd-density` sub-workloads are the ones the OpenShift Performance and
Scale team used to characterise standard against sharded on HCP:

| Workload | What it stresses |
|---|---|
| `event-storm` | Bulk event creation against a concurrent victim workload |
| `crashloop-flood` | Continuous event pressure through the PATCH/count-increment path, which is the shape most real event storms take |
| `db-quota-pressure` | Large object fill driving the backend toward its storage quota |
| `annotation-churn` | Revision bloat from repeated annotation patching |

Their flag sets differ; pass them through `ETCD_PERF_FLAGS` and check
`kube-burner-ocp etcd-density <workload> --help` for what each accepts.

Note that `db-quota-pressure` needs `GC: "false"`, otherwise kube-burner removes
the objects that are supposed to be holding the backend under pressure.

## Gating

`ETCD_MAX_P99_COMMIT_LATENCY_MS` and `ETCD_MAX_LEADER_CHANGES` are both off by
default. When set they should be set generously: their job is to fail a run that
has gone obviously wrong, not to detect regressions. Regression detection is
Orion's, over many runs.
