# Plan: MCE management cluster with Agent NodePool workers on vSphere

## Goal

Introduce a `hypershift-mce-agent-vsphere-conformance` workflow that provisions a management cluster, installs MCE, creates an Agent-platform hosted cluster, and runs guest conformance tests with workers running in vSphere VMs.

The hosted control plane remains on the management cluster. vSphere supplies only worker VMs; it does not host a second standalone OpenShift control plane. The HostedCluster and NodePool use the `Agent` platform, not a native vSphere infrastructure provider.

This is an implementation proposal, not an already validated combination of CI environments. Step names identified as new below are proposed names.

## Scope and decisions to resolve first

1. **Management cluster topology.** The existing manual workflow uses dev-scripts to install management nodes in libvirt VMs on a leased baremetal host. If the requirement is management nodes installed directly on physical servers, use the management provisioning from the baremetal-lab workflow instead. Resolve this before selecting the job's cluster profile and provisioning chain.
2. **Network placement.** Select a management environment and vSphere allocation with a verified connectivity path. Do not assume that the existing CI-side Squid proxy makes management endpoints reachable from vSphere VMs.
3. **Infrastructure allocation.** Decide how to acquire and release vSphere capacity alongside the management allocation. The existing VCM step is gated on `CLUSTER_PROFILE_NAME=vsphere-elastic`; it cannot simply be inserted into the existing management-profile workflow unchanged.
4. **Initial test scope.** Start with a connected IPv4 environment, one hosted cluster, one NodePool, and a fixed number of x86_64 worker VMs. Defer disconnected, dual-stack, heterogeneous pools, and automatic VM scale-out.

Native vSphere cloud integration and CSI are not automatically provided by this design. Define guest storage separately if required by the selected conformance tests.

## Existing implementation to reuse

| Responsibility | Existing source | Reuse approach |
| --- | --- | --- |
| Management provisioning, storage, and MCE | [Manual conformance workflow](ci-operator/step-registry/hypershift/mce/agent/manual/conformance/hypershift-mce-agent-manual-conformance-workflow.yaml) | Keep its setup as the default baseline, subject to the topology decision. |
| Physical management provisioning alternative | [Baremetal-lab workflow](ci-operator/step-registry/hypershift/mce/agent/metal3/conformance/baremetal-lab/hypershift-mce-agent-metal3-conformance-baremetal-lab-workflow.yaml) | Reuse management setup if directly installed physical nodes are required. |
| AgentServiceConfig and HostedCluster creation | [Manual create chain](ci-operator/step-registry/hypershift/mce/agent/manual/create/hypershift-mce-agent-manual-create-chain.yaml) | Retain the relevant creation steps; replace local-network assumptions. |
| InfraEnv, Agent approval, and NodePool scaling | [Manual worker script](ci-operator/step-registry/hypershift/agent/create/add-worker-manual/hypershift-agent-create-add-worker-manual-commands.sh) | Separate platform-independent operations from libvirt boot commands. |
| vSphere capacity and connection context | [VCM setup](ci-operator/step-registry/ipi/conf/vsphere/check/vcm/ipi-conf-vsphere-check-vcm-commands.sh) | Adapt for an auxiliary allocation and explicit lease identity. |
| ISO upload, VM creation, and power-on | [vSphere provision script](ci-operator/step-registry/cucushift/agent/vsphere/provision/cucushift-agent-vsphere-provision-commands.sh) | Extract/adapt the `govc` operations only. |
| Guest tests and diagnostics | `hypershift-mce-agent-info`, `hypershift-conformance`, and existing HCP gather steps | Preserve guest kubeconfig conventions and reuse. |

Do not concatenate the two complete workflows. The standalone vSphere provision step runs `openshift-install agent create image`, creates control-plane VMs, waits for a standalone cluster installation, and overwrites `${SHARED_DIR}/kubeconfig`.

## Implementation phases

### 1. Establish networking and resource contracts

- Identify the vSphere pool, portgroup, datastore, VM sizing, and worker address allocation mechanism.
- Validate connectivity from the selected worker network to management-hosted Assisted Service, image/rootfs services, and the hosted API, ignition, and Konnectivity endpoints. Include DNS, certificates, routing, firewall rules, and any required proxy configuration.
- Validate worker-to-worker connectivity and access to release images, registries, and configured mirrors.
- Plan guest ingress exposure and `*.apps` DNS using a reserved address on the vSphere network or an explicitly configured external load balancer.
- Confirm that the test runner can access the guest API and ingress.
- Ensure the guest machine CIDR matches the worker network and that relevant machine, pod, and service networks do not conflict.

Deliverable: selected environments and a documented endpoint/connectivity plan. Resolve missing routes or endpoint publication before attempting the full workflow.

### 2. Add auxiliary vSphere setup and cleanup

Introduce a proposed `hypershift-agent-vsphere-conf` step or chain:

- Preserve the management cluster profile; mount the necessary vSphere credentials explicitly.
- Reuse the existing leasing/context-generation logic through a parameterized implementation or an adapter appropriate to the chosen CI allocation mechanism.
- Do not reinterpret a management `LEASED_RESOURCE` as a vSphere network or bypass lease ownership checks.
- Record the acquired lease, VM folder, network, datastore, MAC addresses, worker IPs, and reserved ingress address for subsequent steps and cleanup.
- Use a run-specific naming prefix and resource ownership records. Support cleanup after partial setup.
- Implement matching lease release without relying on the global management profile being `vsphere-elastic`.

Suggested new shared files are `vsphere-guest-resources.json` and `vsphere-guest-network.json`. Keep cross-step files directly in `${SHARED_DIR}`; do not rely on arbitrary subdirectories being propagated. Never copy credentials or kubeconfigs into `${ARTIFACT_DIR}`.

### 3. Retain management and hosted control-plane creation

For the dev-scripts baseline, preserve:

- `baremetalds-ofcir-pre`
- Existing catalog/operator preparation
- `hypershift-mce-agent-lvm`
- `hypershift-mce-install`
- `hypershift-mce-agent-create-agentserviceconfig`
- `hypershift-mce-agent-create-hostedcluster`, with any endpoint/network parameterization needed

Set `NUM_EXTRA_WORKERS=0` to avoid allocating unused libvirt guest workers. Use a separate, explicitly declared setting for the vSphere worker count; do not derive it from the standalone installer's `MASTERS + WORKERS` settings.

Create an Agent NodePool with zero replicas initially. Use the HostedCluster's configured Agent namespace consistently rather than selecting the first HostedCluster returned by `oc`.

Preserve these kubeconfig contracts:

- `${SHARED_DIR}/kubeconfig`: management cluster.
- `${SHARED_DIR}/nested_kubeconfig`: hosted cluster, consumed by later guest steps.

### 4. Separate generic Agent preparation from machine booting

Refactor the reusable portions of `hypershift-agent-create-add-worker-manual` into proposed steps such as:

- `hypershift-agent-create-infraenv`: create the InfraEnv and wait for its discovery image.
- `hypershift-agent-create-wait-for-workers`: validate/approve discovered Agents, scale the NodePool, and wait for installation.

Keep libvirt-specific ISO attachment in the existing manual path. If sharing these new steps with that path, preserve its current behavior and validate it independently.

For vSphere:

- Create `NMStateConfig` resources for static IPs, gateways, DNS, and NIC MAC mappings when DHCP is not used. Select them through the InfraEnv; do not generate a standalone installer `AgentConfig`.
- Add a job/pool-specific Agent label and matching NodePool `agentLabelSelector` to avoid claiming unrelated Agents.
- Wait for `InfraEnv` image creation and download the ISO from `.status.isoDownloadURL`.
- Ensure the booted environment can reach the service URLs embedded in the image; successful ISO download from the CI pod is not sufficient proof.

Each step's commands must be available in its CI execution context. Do not call another registry step's script through a repository-relative path at runtime.

### 5. Add vSphere worker creation

Introduce a proposed `hypershift-agent-create-add-worker-vsphere` step using the existing `govc` logic:

1. Upload the InfraEnv ISO to a run-specific datastore path.
2. Create the run-specific VM folder and requested worker VMs.
3. Configure CPU, memory, disk, firmware, NIC/portgroup, and the MAC addresses used in network configuration.
4. Attach the discovery ISO and power on the VMs.
5. Ensure installed machines boot from their disks on subsequent restarts; manage ISO detachment or boot ordering as necessary.

Do not create master VMs, run `openshift-install agent create image`, invoke standalone bootstrap/install waits, or write management authentication files.

The generic worker wait step should then:

- Wait for exactly the expected set of run-owned Agents, using recorded MACs/labels for identification.
- Check eligibility and approve only those Agents.
- Scale the intended NodePool to the requested count.
- Wait for Agent installation and guest Node readiness with bounded timeouts and useful diagnostics.

No BareMetalHost or Metal3 resource is required for these manually booted VMs. NodePool scaling consumes pre-provisioned Agents; it does not itself create additional vSphere VMs.

### 6. Parameterize DNS, endpoint exposure, and ingress

Replace or generalize the local-libvirt assumptions in:

- [DNS configuration](ci-operator/step-registry/hypershift/agent/create/config-dns/hypershift-agent-create-config-dns-commands.sh): currently updates the baremetal host's dnsmasq and libvirt network.
- [Proxy configuration](ci-operator/step-registry/hypershift/agent/create/proxy/hypershift-agent-create-proxy-commands.sh): currently configures CI access through the baremetal host's Squid proxy.
- [Guest MetalLB configuration](ci-operator/step-registry/hypershift/agent/create/metallb/hypershift-agent-create-metallb-commands.sh): currently uses the dev-scripts address `192.168.111.30` for IPv4 ingress.

Publish hosted control-plane endpoints at addresses reachable from the worker network. Publish guest application ingress separately on the worker side. If retaining MetalLB L2 mode, confirm that the selected vSphere network supports the required address advertisements and reserve a suitable address there.

Retain current defaults for existing libvirt workflows when introducing parameters.

### 7. Assemble the workflow and test job

The intended sequence is:

```text
Provision management cluster and install MCE/storage
  -> Acquire auxiliary vSphere capacity and worker networking
  -> Configure Assisted Service and hosted endpoint DNS/exposure
  -> Create Agent HostedCluster and zero-replica NodePool
  -> Create worker network configuration and InfraEnv
  -> Upload ISO, create vSphere worker VMs, and boot them
  -> Approve Agents, scale NodePool, and wait for workers
  -> Configure guest ingress/DNS and validate cluster health
  -> Run existing hosted-cluster conformance tests
  -> Gather diagnostics, destroy guest resources, release both allocations
```

Create the new workflow without changing the standalone `cucushift-agent-vsphere-install-ha` workflow's behavior. Add an initial opt-in/rehearsable job in the agreed HyperShift configuration, with the necessary intranet capability, image dependencies, credentials, and declared environment settings.

### 8. Implement failure-safe cleanup

- Gather HostedCluster, NodePool, Agent, InfraEnv, guest logs, and vSphere VM diagnostics before removing resources.
- Destroy the hosted cluster while management remains available.
- Remove only recorded, run-owned worker VMs, the VM folder, uploaded ISO, and guest DNS/load-balancer resources.
- Release the vSphere allocation after its resources have been removed.
- Tear down the management cluster and release its allocation last.
- Handle partial provisioning and absent files/resources safely. Arrange best-effort post steps so one cleanup failure does not suppress the other cleanup attempts.

Do not reuse broad network-wide VM deletion unless isolation and ownership are explicitly guaranteed.

## Validation and acceptance criteria

- [ ] Run Bash syntax checks and relevant shell linting on changed scripts.
- [ ] Run repository step-registry/configuration validation and applicable generators.
- [ ] Check reference resolution, image tools (`oc`, `govc`, `jq`), credentials, and declared environment variables.
- [ ] Verify connectivity from a VM on the actual leased worker network before full installation.
- [ ] Prove one discovery-booted VM registers an Agent in the intended namespace.
- [ ] Complete the configured NodePool and verify every guest Node maps to a run-owned vSphere VM.
- [ ] Verify hosted control-plane pods remain on management and no vSphere master VMs exist.
- [ ] Verify guest API, application ingress, and any required storage before conformance.
- [ ] Run `hypershift-mce-agent-info` and `hypershift-conformance` using the guest kubeconfig.
- [ ] Rehearse failures during lease acquisition, VM creation, and Agent registration; verify cleanup and diagnostic retention.
- [ ] Verify there are no leftover VMs, ISOs, DNS records, or infrastructure leases after success and failure.
- [ ] Rehearse the original manual flow if its generic Agent logic or defaults were refactored.

Implement incrementally: resolve topology/networking first, prove one vSphere Agent can join, then expand to the full NodePool and conformance workflow.
