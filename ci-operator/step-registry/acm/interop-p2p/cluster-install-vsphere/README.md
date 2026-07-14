# acm-interop-p2p-cluster-install-vsphere

Provisions a single OpenShift spoke cluster on **vSphere** via ACM/Hive
`ClusterDeployment`. Designed to run alongside
[acm-interop-p2p-cluster-install](../cluster-install/) (AWS spoke) in MTV
cross-cluster live-migration (CCLM) jobs where the **source** cluster runs on
vSphere and the **destination** cluster runs on AWS.

## Architecture

```
Hub (AWS, aws-cspi-qe profile)
 ├── ManagedCluster: acm-spoke-{hash}-1   (AWS spoke, index 1 — via acm-interop-p2p-cluster-install)
 └── ManagedCluster: acm-vs-vs-{hash}     (vSphere spoke, index 2 — this step)
```

## Leasing

The vSphere spoke requires a `vsphere-connected-2-quota-slice` Boskos lease.
In the CI job configuration add:

```yaml
leases:
- count: 1
  env: VSPHERE_LEASED_RESOURCE
  resource_type: vsphere-connected-2-quota-slice
```

`VSPHERE_LEASED_RESOURCE` is set by Boskos in the format
`router.datacenter.vlanid` (e.g. `bcr01a.dal10.1153`).

## Credentials

Mounts `vsphere-ibmcloud-config` from `test-credentials` namespace. This
secret contains:

| File | Contents |
|---|---|
| `subnets.json` | VLAN topology: vCenter URL, VIPs, DNS, machine CIDR |
| `load-vsphere-env-config.sh` | Sets datacenter, datastore, cluster, auth path |

The pull-secret and SSH keys come from the hub's `CLUSTER_PROFILE_DIR`
(`aws-cspi-qe` profile).

## Output files

All files are indexed by `ACM_VSPHERE_SPOKE_INDEX` (default `"2"`):

| File | Description |
|---|---|
| `SHARED_DIR/managed-cluster-name-{N}` | Cluster name |
| `SHARED_DIR/managed-cluster-kubeconfig-{N}` | Admin kubeconfig |
| `SHARED_DIR/managed-cluster-metadata-{N}.json` | Hive cluster metadata |

Also appends to batch files created by the AWS install step:
`managed-cluster-names`, `managed-cluster-cluster-network-cidrs`,
`managed-cluster-machine-network-cidrs`, `managed-cluster-service-network-cidrs`.

## CIDR allocation

| Network | Value (index 2) | Notes |
|---|---|---|
| Pod (clusterNetwork) | `10.136.0.0/14` | Formula: `10.{128+idx*4}.0.0/14` |
| Machine (machineNetwork) | From `subnets.json` | VLAN subnet from IBM Cloud |
| Service (serviceNetwork) | `172.32.0.0/16` | Formula: `172.{30+idx}.0.0/16` |

These do not overlap with the hub (index 0) or AWS spoke (index 1).

## Job sequence (typical usage)

```yaml
pre:
- chain: ipi-install           # hub on AWS (aws-cspi-qe profile)
test:
- chain: cucushift-installer-check-cluster-health
- ref: install-operators        # ACM + MTV on hub
- ref: acm-mch                  # MultiClusterHub
- ref: acm-interop-p2p-cluster-install            # AWS spoke (index 1)
- ref: acm-interop-p2p-cluster-install-vsphere    # vSphere spoke (index 2, this step)
- ref: acm-fetch-managed-clusters
- ref: p2p-install-odf-spokes
- ref: p2p-acm-cnv-install-policy
- chain: p2p-mtv-mig-config     # configure MTV providers and maps
- ref: p2p-create-migration-test-vm              # create VM on vSphere spoke
- ref: p2p-mtv-execute-cold-migration            # or live-migration
```

## Key env vars

| Variable | Default | Purpose |
|---|---|---|
| `ACM_VSPHERE_CLUSTER_INITIAL_VERSION` | (required) | OCP version, e.g. `"4.22"` |
| `ACM_VSPHERE_SPOKE_INDEX` | `"2"` | Output file index |
| `ACM_VSPHERE_INSTALL_TIMEOUT_MINUTES` | `"150"` | Provisioning timeout |
| `BASE_DOMAIN` | `cspilp.interop.ccitredhat.com` | Base DNS domain |
| `ACM_VSPHERE_CP_REPLICAS` | `"3"` | Control plane count |
| `ACM_VSPHERE_WORKER_REPLICAS` | `"3"` | Worker count |

## Notes

- vSphere IPI requires at least 3 control plane nodes — enforced by this step.
- The vCenter CA cert is fetched dynamically from the vCenter server using
  `openssl s_client` and stored in a `vsphere-certs` secret for Hive.
- On provisioning failure, the step writes a diagnostics file to
  `${ARTIFACT_DIR}/vsphere-spoke-{name}-install-failure.txt` before exiting.
