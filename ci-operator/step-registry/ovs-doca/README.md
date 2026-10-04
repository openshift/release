# ovs-doca

Steps for testing the NVIDIA DOCA networking stack on OpenShift, by layering DOCA packages
onto RHCOS and installing a cluster whose worker nodes boot that image.

| Component | Purpose |
|---|---|
| `ovs-doca-build-osimage` | Builds the layered RHCOS image from entitled content and stages a day-0 install manifest |
| `ovs-doca-validate-node-package` | Asserts the nodes actually booted it and carry the expected packages |
| `ovs-doca-aws` | Workflow wiring the above into an IPI AWS install |

## Why layering happens in a test step

A ci-operator `images:` build cannot be given a secret. There is no `credentials:` field on
`images.items[]`, `build_args` is plaintext in a public repo, and OpenShift Builds here use
buildah classic rather than BuildKit, so `RUN --mount=type=secret` is unavailable. Entitled
content therefore cannot be fetched during an `images:` build.

Test steps *can* mount `credentials:`, and with `nested_podman: true` they can run
`podman build`. So the layering runs there instead, modelled on
[`mco/conf/day1/enable-ocl`](../mco/conf/day1/enable-ocl).

The image is applied as a **day-0** install manifest: the step writes a `MachineConfig`
carrying `spec.osImageURL` into `${SHARED_DIR}`, which `ipi-install` feeds to the installer.
Nodes come up on the DOCA image rather than being reconfigured afterwards. A plain
`MachineConfig` is used in preference to on-cluster layering (`MachineOSConfig`), because OCL
is documented as AMD64-only and these clusters are arm64.

The step pods run natively on arm64 via `node_architecture_overrides`, so the aarch64 RPM
transaction is not emulated.

## Where the packages come from

The DOCA packages ship in the RHEL 10 **Supplementary** channel — not in a DOCA-specific
repository, and not in Fast Datapath:

```
https://cdn.redhat.com/content/dist/rhel10/<releasever>/aarch64/supplementary/os
```

Verified present for aarch64/el10: `doca-networking-runtime-3.5.0-082000`,
`doca-openvswitch-3.5.0052-1.el10`, `mft-4.37.0-154`, and
`openvswitch-selinux-extra-policy-1.0-41.el10fdp`. Fast Datapath carries only the older
1.0-39 and 1.0-40 builds of the SELinux policy package.

### Red Hat content alone does not resolve

Supplementary ships the DOCA packages without their full dependency closure. Three
requirements have no provider in any Red Hat channel:

| Missing requirement | Required by | Nearest Red Hat package |
|---|---|---|
| `collectx-clxapi >= 1.26.3-1` | `doca-networking-runtime` (direct) | `collectx-bringup-1.22.1-1` |
| `libmlx5.so.1(MLX5_1.25.1)(64bit)` | `doca-openvswitch` | `libibverbs-61.0-1.el10` |
| `libmlx5.so.1(MLX5_1.27)(64bit)` | `doca-openvswitch` | `libibverbs-61.0-1.el10` |

`doca-networking-runtime` requires `doca-openvswitch`, so all three apply to it.

Two root causes:

1. **collectx is stale and differently named.** `collectx-bringup-1.22.1-1` does provide
   `libclx_api.so.1(CLX_API)(64bit)`, but DOCA requires the package name `collectx-clxapi`
   at `>= 1.26.3-1`. Wrong name, and four minors behind, so a `Provides:` alias alone would
   not satisfy it.
2. **DOCA-OFED's rdma-core is absent.** Those MLX5 symbols come from NVIDIA's `rdma-core`
   family, versioned `2607.0.8-1.el10`. Red Hat ships a separate lineage topping out at
   `61.0-1.el10`. Different packages, not an upgrade path.

### The hybrid

A small NVIDIA repository is layered underneath at dnf `priority=99` while the Red Hat
repositories sit at `priority=1`, so Red Hat content wins wherever it exists and NVIDIA is
reached for only what Red Hat lacks. Measured on DOCA 3.5.0 / aarch64 / el10:

```
142 packages total
135 from Red Hat  -- including all four wanted packages
  7 from NVIDIA   -- collectx-clxapi, libibverbs, libibumad, librdmacm,
                     infiniband-diags, rdma-core-devel, openmpi
```

Set `OVS_DOCA_NVIDIA_BASEURL` to an empty string to re-test Red Hat alone once the channel
gaps close. Note the arch path component on NVIDIA's repository is `arm64-sbsa`, not
`aarch64`.

## Two install flags that are load-bearing

- **`--setopt=install_weak_deps=False`** — the DOCA stack *Recommends* `openvswitch3.5` from
  Fast Datapath, which silently reinstates the stock openvswitch that `OVS_DOCA_REMOVE_PACKAGES`
  just removed. Confirmed both ways: present with weak deps on, absent with them off.
- **`--allowerasing`** — lets NVIDIA's rdma-core family replace the stock one in the CoreOS
  base. RPM treats `2607.0.8` as newer than `61.0`, so this is an upgrade. If a future base
  image makes it a genuine conflict, this is the line that will need
  `rpm-ostree override replace` instead.

## libunwind is not a RHEL 10 package

Earlier revisions of the package list included `libunwind`. No package of that name exists in
RHEL 10 — not in BaseOS, AppStream, CRB, Supplementary or Fast Datapath — nor any package with
`unwind` in its name, nor any provider of `libunwind.so.8()(64bit)` or `libunwind.so.1()(64bit)`.
Nothing in the DOCA stack requires it.

Listing it is actively harmful rather than merely redundant: dnf fails with
`Unable to find a match: libunwind` before evaluating the DOCA dependency tree at all, which
hides the real blockers above.

## Reproducing the dependency analysis

On any aarch64 host with podman and a Red Hat activation key, no cluster required:

```bash
podman run --rm --platform linux/arm64 -v "$PWD:/creds:ro" \
  registry.access.redhat.com/ubi10/ubi:latest bash -c '
    rm -rf /etc/rhsm-host /etc/pki/entitlement-host
    sed -i "s/^disable_plugin=1/disable_plugin=0/" /etc/dnf/plugins/subscription-manager.conf
    subscription-manager register --org="$(cat /creds/org)" --activationkey="$(cat /creds/key)"
    subscription-manager repos --disable="*"
    for c in baseos appstream supplementary; do
      subscription-manager repos --enable "rhel-10-for-aarch64-${c}-rpms"
    done
    subscription-manager repos --enable fast-datapath-for-rhel-10-aarch64-rpms
    dnf -y install --assumeno --setopt=install_weak_deps=False \
      doca-networking-runtime openvswitch-selinux-extra-policy mft
    subscription-manager unregister'
```

Omit the NVIDIA repository to see the three unsatisfied requirements; add it at
`priority=99` to see the transaction resolve.

## Credentials

Both steps read from the `ovs-doca` secret collection in the `test-credentials` namespace,
registered against the `rh-ecosystem-nvidia` Rover group in
`core-services/sync-rover-groups/_config.yaml`. Collection names are declared in this repo;
the values are written separately via the
[GSM Secret Manager CLI](https://docs.ci.openshift.org/docs/how-tos/adding-a-new-secret-to-ci-gsm/).

| Secret | Keys | Notes |
|---|---|---|
| `rhsm-activation-key` | `entitlement.pem`, `entitlement-key.pem`, optionally `redhat-uep.pem` | Preferred. No registration round-trip, no root needed. Certificates expire and need rotation. |
| `rhsm-activation-key` | `subscription-manager-org`, `subscription-manager-act-key` | Fallback. Requires `subscription-manager` in the step image and write access to `/etc/pki/entitlement`; a pod killed before the EXIT trap leaves a registered system behind. |
| `quay-push` | `auth` | Base64 `user:token` for pushing the layered image. |

`OVS_DOCA_IMAGE_REPO` must be publicly readable, or the cluster pull secret must already
carry credentials for it — nodes pull the OS image during install, before the cluster and its
internal registry exist.
