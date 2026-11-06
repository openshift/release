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

Nothing in this directory contains a metrics query. The endpoint file names
kube-burner-ocp's own `etcd-density-metrics-hcp.yml` and `metrics.yml` and
kube-burner resolves them out of the binary, so there is one copy of them and it
is owned by the team that owns the measurements.

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
- The hosted control plane's etcd and kube-apiserver ServiceMonitors drop
  everything outside a short keep list unless the HyperShift operator was
  installed with `--metrics-set=All`, so the jobs set `METRICS_SET: All` on
  `hypershift-install`. Under the operator default, `Telemetry`, six etcd series
  survive and the rest, including `etcd_cluster_version`, never reach Prometheus.

`hypershift-hcp-metrics-endpoint` also verifies that etcd series are actually
arriving before the workload starts, so a job cannot burn hours producing load
and no measurement.

The `kube-burner-ocp-wrapper` in `e2e-benchmarking` does have a
hosted-control-plane mode, but its AWS path is ROSA specific: it derives the
control plane namespace from the `api.openshift.com/name` resource tag and
expects an Observability Operator route on the management cluster. Neither holds
on the self-managed HyperShift CI lanes, so its discovery is not reused.

## Per-shard breakdown

The profiles are `etcd-density-metrics-hcp.yml` and `metrics.yml`, both of them
kube-burner-ocp's own. The first scopes every etcd and kube-apiserver query to
the hosted control plane namespace and aggregates `by (pod)`, so each shard is
reported separately — pod names carry the shard (`etcd-0`, `etcd-events-0`,
`etcd-leases-0`). It also binds `{{.HOSTED_CLUSTER_NAMESPACE}}`, which the
workload step exports from `${SHARED_DIR}/hcp-namespace`.

Nothing resolves profiles from this repo or from `e2e-benchmarking`. kube-burner
looks a profile name up on disk first and then in the profiles embedded in the
binary, so naming them in the endpoint file gets the tool's own copies at
whatever `KUBE_BURNER_VERSION` the workload step runs.

The shard topology in effect is also recorded verbatim, in
`hostedcluster-etcd-spec.json` and `etcd-statefulsets.txt` in the artifact
directory.

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
  - name: leases
    replicas: 3
    resources:
    - apiGroup: coordination.k8s.io
      resource: leases
    storage:
      type: PersistentVolume
  - name: events
    replicas: 1
    resources:
    - apiGroup: ""
      resource: events
    - apiGroup: events.k8s.io
      resource: events
    storage:
      type: EmptyDir
```

That is seven etcd pods in the hosted control plane namespace:

| Shard | StatefulSet | Pods | Storage |
|---|---|---|---|
| main | `etcd` | `etcd-0`, `etcd-1`, `etcd-2` | PersistentVolume |
| `leases` | `etcd-leases` | `etcd-leases-0`, `etcd-leases-1`, `etcd-leases-2` | PersistentVolume |
| `events` | `etcd-events` | `etcd-events-0` | EmptyDir |

The three main members come from `HYPERSHIFT_CP_AVAILABILITY_POLICY:
HighlyAvailable`, not from the shard list — the main shard is not named in
`spec.etcd.managed.shards`, it is what everything not routed to a listed shard
falls through to. The standard job creates the same three and nothing else.

`HYPERSHIFT_ETCD_SHARDS` is set verbatim as `spec.etcd.managed.shards` on the
HostedCluster. There is no `hypershift create cluster` flag for it, so
`hypershift-aws-create` renders the manifests, splices the list in and applies
the result; the field is immutable once the HostedCluster exists, so it cannot
be patched on after creation.

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

Elasticsearch, under the run's UUID, which is what the perf and scale Grafana
dashboards read. The endpoint file carries two entries over the same Thanos and
the same profiles — an entry holds exactly one indexer — so the series are also
written to `collected-metrics-<uuid>/` in the artifact directory and a failed
run can be read without an Elasticsearch query.

One wart, in the `openshift-qe` step. `kube-burner-ocp` declares `--es-server`
and `--metrics-endpoint` mutually exclusive, and the hosted control plane series
only exist on the endpoint, so `run.sh` must not add `--es-server`. It adds it
whenever `ES_SERVER` is set, and `ES_SERVER` has to stay set: the endpoint file
resolves `{{.ES_SERVER}}` from the environment, and `index.sh` needs it for the
CI fingerprint. So the step drops that one line from `run.sh` rather than
clearing the variable, and fails loudly if the line is not where it expects. The
real fix is a self-managed HyperShift branch in `run.sh` next to its ROSA and
ARO ones, which is `e2e-benchmarking`'s to make.

No credential handling lives in this directory. The Elasticsearch server reaches
the endpoint file as a `{{.ES_SERVER}}` placeholder that kube-burner resolves at
run time; the password itself is read only by the `openshift-qe` workload step,
which already owned that code before this chain existed.
