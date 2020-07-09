# OpenShift Prow instance

Manifests and configuration of the OpenShift instance of [Prow](https://github.com/kubernetes/test-infra/blob/master/prow/README.md)
running on the api.ci cluster.

## Boskos

The CI clusters provide a [Boskos][] service which manages platform-specific leases to avoid failing jobs based on available capacity (e.g. VPC limits or throttling on AWS).
Per-platform administrators [configure lease capacity][boskos-lease-config] to reflect the currently-available capacity for each account.
Cluster-launching jobs acquire leases before launching a cluster, and release them after tearing the cluster back down.
When capacity is exhausted, jobs may wait some time before a lease becomes available.
If no leases become available, the job may fail on a lease timeout.

[Boskos]: https://github.com/kubernetes-sigs/boskos#boskos
[boskos-lease-config]: 02_config/_boskos.yaml
