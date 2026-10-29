# hypershift-etcd-perf

Runs one `kube-burner-ocp etcd-density` workload against a HyperShift hosted
cluster and measures the hosted control plane's etcd while it runs.

This exists to give etcd sharding a periodic measurement, as opposed to the
`e2e-*-etcd-sharding` jobs, which are functional: they assert that shards get
deployed, that the kube-apiserver is given the right `--etcd-servers-overrides`,
that keys land in the shard they are routed to, and that the shards survive a
restart. Those jobs deliberately measure nothing. This one produces numbers and
nothing else.

## Shape

The chain is deliberately three small steps rather than one script, so that the
only HyperShift-specific part is the plumbing and the workload itself is the
perf and scale team's own step, used unmodified:

| Step | Owner | What it does |
|---|---|---|
| `hypershift-enable-user-workload-monitoring` | HyperShift | Turns on user workload monitoring on the management cluster |
| `hypershift-hcp-metrics-endpoint` | HyperShift | Resolves the management cluster's Thanos, writes the kube-burner endpoint file |
| `openshift-qe-etcd-density-annotation-churn` | perf and scale | Runs the workload |

Nothing in this directory contains a metrics query. The queries come from
`metrics-profiles/` in `cloud-bulldozer/e2e-benchmarking`, at the same tag the
`openshift-qe` workload steps resolve, so there is one copy of them and it is
owned by the team that owns the measurements.

## Why a hosted cluster needs the extra plumbing

On a standalone cluster, kube-burner points at one cluster and finds etcd in
`openshift-etcd` on that same cluster. On a hosted cluster the two halves are on
different clusters: the load lands on the guest API server, but the etcd under
test is a set of pods in `clusters-<name>` on the management cluster. Two things
follow:

- Those pods are in a user namespace, so nothing scrapes their ServiceMonitors
  until user workload monitoring is enabled.
- kube-burner's own Prometheus discovery finds the cluster in `KUBECONFIG`,
  which is the guest. The series it needs are on the other one, so it is handed
  an explicit endpoint instead.

`hypershift-hcp-metrics-endpoint` also verifies that etcd series are actually
arriving before the workload starts, so a job cannot burn hours producing load
and no measurement.

The `kube-burner-ocp-wrapper` in `e2e-benchmarking` does have a
hosted-control-plane mode, but its AWS path is ROSA specific: it derives the
control plane namespace from the `api.openshift.com/name` resource tag and
expects an Observability Operator route on the management cluster. Neither holds
on the self-managed HyperShift CI lanes. Its *profiles* are reused; its
discovery is not.

## Per-shard breakdown

Not there yet. The upstream `rosa/hosted-cp-metrics.yml` aggregates etcd series
across the control plane namespace without a `by (pod)` breakdown, so a sharded
run currently reports the shards summed together. Because the pod names carry
the shard name (`etcd-0`, `etcd-events-0`, `etcd-leases-0`, ...), splitting them
is a `by (pod)` away — but that belongs in `e2e-benchmarking` next to the rest
of the queries, not in a copy of the profile here. Until that lands, the shard
topology in effect is recorded in `hostedcluster-etcd-spec.json` and
`etcd-statefulsets.txt` in the artifact directory.

## Comparing standard against sharded

The chain does not compare topologies. It measures whichever hosted cluster it
is pointed at. A comparison is two jobs on the same schedule running the same
workload with the same flags, where one creates the hosted cluster with
`HYPERSHIFT_ETCD_SHARDS` set and the other does not.

The shard topology the jobs use is the one agreed with the perf and scale team:
three PersistentVolume-backed main etcd members, a three-member
PersistentVolume-backed `leases` shard so that cluster heartbeat signals get
their own highly available shard, and a single EmptyDir-backed `events` shard.

```yaml
HYPERSHIFT_CP_AVAILABILITY_POLICY: HighlyAvailable   # the three main members
HYPERSHIFT_ETCD_SHARDS: |-
  name=leases,resources=coordination.k8s.io/leases,replicas=3,storage=PersistentVolume
  name=events,resources=/events;events.k8s.io/events,replicas=1,storage=EmptyDir
```

`EtcdSharding` is a `TechPreviewNoUpgrade` management cluster feature gate, so
the sharded job also needs `TECH_PREVIEW_NO_UPGRADE: "true"`.

## Workloads

The four `etcd-density` sub-workloads are the ones the OpenShift Performance and
Scale team used to characterise standard against sharded on HCP:

| Workload | What it stresses | `openshift-qe` step |
|---|---|---|
| `annotation-churn` | Revision bloat from repeated annotation patching | yes |
| `db-quota-pressure` | Large object fill driving the backend toward its storage quota | yes |
| `crashloop-flood` | Continuous event pressure through the PATCH/count-increment path, which is the shape most real event storms take | not yet |
| `event-storm` | Bulk event creation against a concurrent victim workload | not yet |

They are added one per pull request, starting with `annotation-churn`. Adding
one is swapping the last ref of the chain, plus writing the `openshift-qe` step
for it if there is not one yet.

`db-quota-pressure` needs `GC: "false"`, otherwise kube-burner removes the
objects that are supposed to be holding the backend under pressure. Its
`openshift-qe` step already defaults it that way.

## Results

`collected-metrics-<uuid>/` in the artifact directory.

Not Elasticsearch, yet, and so not Orion. `run.sh` in `e2e-benchmarking` passes
either `--metrics-endpoint` or `--es-server` to kube-burner, never both, and the
hosted control plane series only exist on the endpoint. Its existing
hosted-control-plane mode would resolve that, but it only knows ROSA and ARO;
giving it a self-managed HyperShift branch is what unblocks indexing, and it
belongs in that repo. Until then these jobs are read from their artifacts.

No credential handling lives in this directory. The one Elasticsearch password
in the chain is read by the `openshift-qe` workload step, which already owned
that code before this chain existed.
