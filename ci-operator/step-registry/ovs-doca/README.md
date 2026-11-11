# OVS-DOCA CI variant (`4.22-stable-ovs-doca`)

Day0 RHCOS image layering of DOCA-enabled OVS for `rh-ecosystem-edge/nvidia-ci`,
plus an e2e AWS rehearsal that installs a cluster with the layered image and
validates it on every node.

## What it does

Instead of rolling DOCA OVS out post-install (day2: runtime `podman build` +
`MachineConfig`/MCO), this variant bakes `doca-openvswitch` (and `mft`) into
RHCOS at ci-operator's image-build stage and folds the built image into the
4.22 release payload via `releases.latest.integration.include_built_images`.
Nodes boot with the DOCA-enabled OVS from install time. No external registry,
no MCO rollout.

The image build (a `dockerfile_literal` in the [config](../../config/rh-ecosystem-edge/nvidia-ci/rh-ecosystem-edge-nvidia-ci-main__4.22-stable-ovs-doca.yaml)):

1. Predownloads `unbound` (+deps) from CentOS Stream 9 — required by
   `doca-openvswitch`, unreachable from the build farm (no RHEL entitlement).
2. Detects the RHEL major from the base image's `/etc/os-release` and writes
   the DOCA repo pin (see [version pinning](#version-pinning) below).
3. `rpm-ostree override replace libibverbs rdma-core` from the DOCA repo.
4. Removes the stock Fast Datapath `openvswitch[0-9]*`, installs
   `doca-openvswitch` + `mft`.
5. Stashes the `collectx-clxapi` payload under `/usr/lib/doca-collectx-payload`
   and restores it at boot via an `ovsdb-server.service` drop-in —
   `/opt` is a symlink to `/var/opt` on ostree and `ostree container commit`
   discards `/var`.
6. Ships a `tmpfiles.d` fragment recreating the OVS runtime directories with
   `openvswitch:hugetlbfs` ownership (same `/var` reason).
7. `ostree container commit`.

## How to run it

The test is `always_run: false`; it is exercised via rehearsal, not on every
PR. Comment on a PR touching this config:

```
/pj-rehearse pull-ci-rh-ecosystem-edge-nvidia-ci-main-4.22-stable-ovs-doca-e2e-aws-nodes-check
```

Pipeline: image build (~5 min) → AWS IPI install (~45 min) → validation
(~1 min) → publish credentials → hold → teardown. **Do not push new commits
to the PR while a rehearsal is running** — pj-rehearse cancels rehearsal jobs
when the PR head changes.

## Controllable parameters

All parameters below are env entries in the
[config](../../config/rh-ecosystem-edge/nvidia-ci/rh-ecosystem-edge-nvidia-ci-main__4.22-stable-ovs-doca.yaml)
(test `e2e-aws-nodes-check`) or in the step ref. Changing them means editing
the config in the PR — `/pj-rehearse` does not accept per-run overrides.

### Cluster shape and install

| Env | Default | Meaning |
|-----|---------|---------|
| `OCP_ARCH` | `amd64` | Cluster architecture. AWS instance types derive from it. arm64 is a separate future variant (DOCA publishes aarch64 as `arm64-sbsa`). |
| `CONTROL_PLANE_REPLICAS` | `1` | Control-plane node count. |
| `COMPUTE_NODE_REPLICAS` | `1` | Worker node count. |
| `BASE_DOMAIN` | `edge-sro.rhecoeng.com` | DNS base for the throwaway cluster. |

### Validation step (`ovs-doca-validate-node-package`)

| Env | Default | Meaning |
|-----|---------|---------|
| `OVS_DOCA_VALIDATE_NODE_ROLES` | `master worker` | Space-separated node roles to validate. The layered image is in the release payload, so it lands on every node. |
| `OVS_DOCA_EXPECTED_RPM_VERSION` | `3.4.0040-1.el9` | Exact `VERSION-RELEASE` of `doca-openvswitch` the nodes must have. NOT the DOCA train number — see below. |

### Debugging hold (`hold-cluster`)

| Env | Default | Meaning |
|-----|---------|---------|
| `OVS_DOCA_CLUSTER_HOLD_MINUTES` | `15` | Minutes the cluster stays up after validation, for manual work, before the post chain tears it down. The step logs a heartbeat every 5 minutes with the time remaining. |

### Version pinning

The DOCA train is pinned in the `dockerfile_literal`'s repo URL
(`.../repo/doca/<train>/rhel${RHEL_MAJOR}/x86_64/`). The train number and the
rpm NEVRA are **different numbers** and must be bumped **together**:

| DOCA train (repo URL) | rpm `VERSION-RELEASE` (`OVS_DOCA_EXPECTED_RPM_VERSION`) |
|-----------------------|----------------------------------------------------------|
| 3.4.1 | `3.4.0040-1.el9` |
| 3.2.2 | `3.2.2010-1.el9` |

The OCP payload floats to the latest accepted 4.22 nightly
(`releases.latest.integration`) — this is deliberate: the `release:` config
type (stable-channel pinning) does not support `include_built_images`, which
the day0 layering depends on. The RHCOS base image floats with it and is
resolved to a digest once per job.

## Working with the live cluster during the hold

The `publish-cluster-access` step copies `kubeconfig` and `kubeadmin-password`
into the job artifacts; step artifacts sync to GCS when the step's container
finishes, so they are downloadable while the hold is running. From the
[prow job view](https://prow.ci.openshift.org/) (Artifacts / spyglass):

```
.../artifacts/e2e-aws-nodes-check/publish-cluster-access/artifacts/kubeconfig
.../artifacts/e2e-aws-nodes-check/publish-cluster-access/artifacts/kubeadmin-password
```

```bash
export KUBECONFIG=$PWD/kubeconfig
oc get nodes                                   # 1 control-plane + 1 worker
oc debug node/<name> -- chroot /host           # root shell on any node
```

Direct SSH is not available: IPI nodes live in private subnets with no public
IPs and no bastion. `oc debug node/` is the supported access path.

## What is and is not validated

Validated per node (see the
[step](validate/node-package/ovs-doca-validate-node-package-ref.yaml) docs for
the full list): service health, package installed/replaced, `datapath_types`
includes `doca`, `netdev` and `system`, offload keys false-or-absent, exact rpm
version, and an applicative test that forwards real packets (veth pair across
an isolated test bridge).

**Not** validated: hardware offload (needs a ConnectX/BlueField NIC; AWS has
none), SELinux policy coverage (`doca-openvswitch` ships none — printed as a
diagnostic only), and functional network behavior beyond the datapath test.

## Where things live

| File | Contents |
|------|----------|
| `ci-operator/config/rh-ecosystem-edge/nvidia-ci/rh-ecosystem-edge-nvidia-ci-main__4.22-stable-ovs-doca.yaml` | Variant config: image build, cluster shape, test steps, hold/publish steps |
| `ci-operator/step-registry/ovs-doca/validate/node-package/` | The validation step (script, ref, OWNERS) |
| `ci-operator/jobs/rh-ecosystem-edge/nvidia-ci/rh-ecosystem-edge-nvidia-ci-main-presubmits.yaml` | Generated presubmit job wiring (do not hand-edit) |
