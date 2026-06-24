# ROSA Cluster Lease

This namespace manages pre-provisioned ROSA clusters for operator e2e testing.

**This is NOT a Hive ClusterPool.** ROSA clusters are provisioned through OCM
(not the OpenShift installer), so Hive ClusterPool CRDs cannot be used. Instead,
this uses ConfigMaps as lightweight state tracking for lease management.

## How it works

- Each ROSA cluster is represented by a ConfigMap with labels for type, env,
  region, version, and availability status
- Prow jobs claim clusters via optimistic concurrency (CAS with `oc replace`)
- A periodic controller provisions, health checks, and replaces clusters
- Stale leases from crashed jobs are automatically recovered

## ConfigMap labels

- `rosa-cluster-lease/managed: "true"` - managed by the controller
- `rosa-cluster-lease/status` - `available`, `in-use`, `maintenance`, `error`
- `rosa-cluster-lease/type` - cluster type (e.g., `classic-sts`)
- `rosa-cluster-lease/env` - OCM environment (`staging`, `integration`)
- `rosa-cluster-lease/region` - AWS region
- `rosa-cluster-lease/version` - OCP minor version (e.g., `4.22`)

## Step registry refs

- `rosa-cluster-lease-checkout` - claim a cluster for testing
- `rosa-cluster-lease-checkin` - return a cluster after testing
- `rosa-cluster-lease-health` - periodic health check
- `rosa-cluster-lease-controller` - full lifecycle controller
- `rosa-cluster-lease-e2e-workflow` - operator e2e workflow using leased clusters

## Jira

- [ROSAENG-59268](https://redhat.atlassian.net/browse/ROSAENG-59268)
