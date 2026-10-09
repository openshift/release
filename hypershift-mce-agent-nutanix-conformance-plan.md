# Plan: MCE Agent HostedCluster with Nutanix worker VMs

## Goal

Create a separate, initially informational HyperShift conformance flow with:

- The existing baremetal-backed management-cluster setup and profile.
- MCE installed on the management cluster; the HostedCluster control plane runs there.
- Nutanix VMs used only as Agent-based HostedCluster NodePool workers.
- The existing HCP Agent workflow and conformance chain retained as the baseline.

The Nutanix VMs must boot the discovery ISO produced by the MCE `InfraEnv`. Do not use
`openshift-install agent create image`: that creates a standalone cluster installation ISO and
expects standalone control-plane/bootstrap behavior. Do not create Nutanix VMs for the HostedCluster
control plane.

This is a separate HCP-specific flow. Leave the existing standalone `agent-qe-nutanix` workflow
unchanged. Do not wire this flow into a CI workflow/job yet; that remains optional and informational.

## Agreed design decisions

- Preserve the current management-cluster layout and its `cluster_profile`/OFCIR allocation.
- Acquire a separate Nutanix quota-slice lease and mount its credentials explicitly. Do not replace
  the management `cluster_profile` with the Nutanix profile.
- Use a dedicated HCP provisioning entrypoint that reuses the Nutanix ISO-upload and VM-provisioning
  roles, but skips standalone ISO mutation, rendezvous-IP assignment, and standalone installer waits.
- Start with three fixed workers, each using the existing Nutanix worker baseline: 8 vCPUs, 16 GB RAM,
  and a 120 GB disk. Do not enable autoscaling.
- Prefer DHCP on the selected Nutanix subnet. If DHCP is unavailable, configure worker networking with
  `NMStateConfig` and ensure the matching network configuration is included before the discovery ISO is
  generated. Do not set `RENDEZVOUS_IP` for HCP workers.
- Use run-specific Agent selection and approve only the expected three workers.
- Remove only this run's Nutanix VMs and uploaded image, using recorded UUIDs.
- Route discovery and installed worker traffic through the existing Squid proxy.
  Reachability from the actual Nutanix worker network is a required validation, not an assumption.

## Existing implementation to reuse

| Responsibility | Existing source | Reuse or adaptation |
| --- | --- | --- |
| Management cluster and MCE baseline | [`hypershift-mce-agent-metal3-conformance`](ci-operator/step-registry/hypershift/mce/agent/metal3/conformance/hypershift-mce-agent-metal3-conformance-workflow.yaml) | Preserve its management setup, catalog/operator preparation, MCE install, and guest conformance flow. Substitute the Nutanix worker chain for the Metal3 worker-provisioning chain. |
| HostedCluster and Agent NodePool creation | [`hypershift-mce-agent-create-hostedcluster`](ci-operator/step-registry/hypershift/mce/agent/create/hostedcluster/hypershift-mce-agent-create-hostedcluster-commands.sh) | Retain the existing Agent HostedCluster design and endpoint conventions. Create the NodePool at zero replicas initially. |
| InfraEnv and manual Agent worker flow | [`hypershift-agent-create-add-worker-manual`](ci-operator/step-registry/hypershift/agent/create/add-worker-manual/hypershift-agent-create-add-worker-manual-commands.sh) | Reuse the generic InfraEnv, Agent discovery, approval, and NodePool scaling concepts. Keep libvirt ISO attachment and host access out of the Nutanix implementation. |
| Nutanix lease and credentials | Existing Nutanix quota-slice lease/profile and secrets | Acquire a second lease without changing the management profile. Export its identity distinctly (for example, `NUTANIX_LEASED_RESOURCE`) and mount only the Nutanix credentials needed by the Nutanix step. |
| Nutanix ISO upload and VM provisioning | `agent-qe-nutanix-provision` in this repo and the `agent-qe-infra` checkout's `ansible-files/roles/nutanix/upload_image` and `provision_vm` roles | Reuse these lower-level roles and their UUID bookkeeping. Add an HCP-specific Ansible entrypoint that does not include the standalone `update_ignition` role. |
| Hosted diagnostics and tests | `hypershift-mce-agent-info`, existing HCP gather steps, `hypershift-conformance` | Preserve the management/guest kubeconfig contracts and collect guest Agent, InfraEnv, NodePool, and VM diagnostics. |

The existing [`hypershift-mce-agent-metal3-create` chain](ci-operator/step-registry/hypershift/mce/agent/metal3/create/hypershift-mce-agent-metal3-create-chain.yaml)
is a reference for step ordering, not a chain to copy wholesale: it creates Metal3/BareMetalHost
resources and uses libvirt/dev-scripts network assumptions that do not apply to Nutanix.

## Implementation phases

### 1. Define the two resource allocations and credentials

- Keep the existing baremetal-backed management allocation and `cluster_profile` exactly as used by
  the selected MCE Agent conformance baseline.
- Request Nutanix capacity through a separate lease/quota-slice allocation. Do not use the management
  `LEASED_RESOURCE` as the Nutanix subnet or VM allocation identifier.
- Record the Nutanix lease identity separately, such as `NUTANIX_LEASED_RESOURCE`, and derive the
  Nutanix Prism host, cluster, storage container, and subnet from that lease's metadata.
- Mount Nutanix username/password and any required API endpoint explicitly from the Nutanix lease.
  Do not read Nutanix credentials from the management `CLUSTER_PROFILE_DIR` or overwrite its
  `secrets.sh`/lease context.
- Ensure the release step execution image contains the required Ansible/Nutanix collection and tools.
  Keep lease credentials, kubeconfigs, and pull secrets out of `${ARTIFACT_DIR}`.
- Make cleanup release the Nutanix lease only after run-owned Nutanix resources have been deleted;
  release the management allocation last through its existing cleanup path.

Deliverable: a documented mapping from the Nutanix lease to its credentials, Prism endpoint, target
cluster, storage container, and VM network/subnet UUID.

### 2. Create the HostedCluster and zero-replica NodePool

- Retain the Agent-platform HostedCluster design and hosted API/ingress conventions from the existing
  HCP workflow. Adapt only environment/network-specific values where the Nutanix worker network
  requires it.
- Set the initial NodePool replica count to zero so workers are not expected before Nutanix VMs boot
  and register as Agents.
- Keep management and guest kubeconfig paths unambiguous:
  - `${SHARED_DIR}/kubeconfig`: management cluster.
  - `${SHARED_DIR}/nested_kubeconfig`: HostedCluster, for later guest steps.
- Use one explicit HostedCluster name and Agent namespace through all steps. Avoid selecting the first
  HostedCluster or all Agents returned by cluster-wide queries.

### 3. Prepare the MCE InfraEnv and discovery ISO

Add or adapt an HCP-specific InfraEnv step that:

- Creates the pull-secret reference, SSH key, architecture (`x86_64`), and run-specific identity.
- Uses the configured Agent namespace and creates a unique InfraEnv name for this job/run.
- Configures the InfraEnv's proxy fields as described in phase 6.
- Waits for `ImageCreated`, reads `.status.isoDownloadURL`, and downloads the InfraEnv-generated
  discovery ISO to the path/name expected by the Nutanix upload role.
- Does not create or pass a standalone `AgentConfig` with `rendezvousIP`.

The ISO is generated by MCE Assisted Service for registering worker Agents with the HostedCluster.
Downloading the ISO successfully in the CI pod is not proof that a booted Nutanix VM can reach the
services embedded/configured for discovery; validate that separately in phase 6.

For the agreed DHCP-first baseline, do not create NMStateConfig resources. If the selected Nutanix
subnet lacks usable DHCP, add a static-network branch:

1. Obtain and record each VM NIC MAC address before finalizing the InfraEnv image.
2. Create one run-scoped `NMStateConfig` per worker with its static address, prefix, gateway, DNS,
   and MAC mapping.
3. Select those configs from the InfraEnv using `nmStateConfigLabelSelector` and wait for image
   regeneration before booting any VM.
4. Ensure addresses are reserved, unique, routable, and outside conflicting DHCP/IPAM allocations.

Do not use `RENDEZVOUS_IP` as a substitute for DHCP or worker static-network configuration. In the
existing standalone flow it identifies the standalone bootstrap host and is also passed to the first
VM as `private_ip`; an HCP worker has no standalone rendezvous role.

### 4. Provision only the three Nutanix worker VMs

Create a new HCP-specific Nutanix provisioning entrypoint, leaving the standalone workflow and its
behavior unchanged:

- Produce a hostnames file containing only three run-unique worker names, such as
  `<cluster>-worker-0` through `<cluster>-worker-2`; do not include masters or bootstrap VMs.
- Set `AGENT_IMAGE` to the downloaded InfraEnv ISO filename and pass the Nutanix lease's endpoint,
  credentials, cluster, storage container, and subnet UUID to Ansible.
- Reuse the existing image upload and VM-provisioning roles in `agent-qe-infra`.
- Do not invoke `nutanix/update_ignition`. The existing `nutanix_provision_vm.yml` wrapper runs that
  standalone-specific role when there is more than one VM; the HCP InfraEnv ISO is not the standalone
  ISO that role was written to mutate.
- Leave rendezvous/private-IP assignment empty for the DHCP baseline. If the static fallback is used,
  use the per-worker NMState configuration and any required Nutanix IPAM reservation consistently;
  do not assign a special address to worker 0 solely because it is first in the list.
- Retain the existing worker VM sizing baseline: 8 vCPUs, 16 GB RAM, and a 120 GB disk per VM.
- Attach the discovery ISO as CD-ROM and boot each VM. Validate the Nutanix boot order: the current
  role orders disk before CD-ROM, so prove that a new blank VM falls through to the ISO. After
  installation, ensure workers boot from disk and detach the ISO or set boot order as appropriate.
- Preserve run ownership and write each VM UUID and uploaded image UUID to shared state for cleanup.
- Do not run the standalone caller's `openshift-install agent wait-for bootstrap-complete`,
  `agent wait-for install-complete`, or standalone cluster stability wait. HCP/NodePool status owns
  worker installation and readiness.

The existing Nutanix VM role accepts a list of names and creates only those VMs, but the current
standalone wrapper combines that role with standalone ISO mutation. Reuse the roles behind the HCP
entrypoint rather than calling the existing standalone workflow unchanged.

### 5. Select, approve, and install only this run's Agents

- Use the unique InfraEnv identity/run labels to isolate the expected three Agents. Configure the
  NodePool's Agent label selector to match only these Agents.
- Wait for exactly three matching Agent resources and verify their reported hostname/MAC addresses
  map to the VMs recorded for this run.
- Approve only those three Agents after requirements/eligibility checks; never approve every Agent in
  the Agent namespace or management cluster.
- Scale the intended NodePool from zero to three replicas after the matching Agents are present and
  approved.
- Wait with bounded timeouts for all three Agents to be added to the existing HostedCluster and for
  all three guest Nodes to become Ready. On failure, gather InfraEnv, Agent, NodePool, HostedCluster,
  VM task, and worker boot diagnostics before cleanup.
- Keep autoscaling disabled for this initial flow. NodePool scaling consumes already provisioned
  Agents; it does not create or delete Nutanix VMs.

### 6. Configure the proxy and validate worker-network connectivity

Implement the same discovery/guest proxy pattern with the Nutanix VM network and endpoints:

- Configure `InfraEnv.spec.proxy` with the reachable Squid URL in the HTTP/HTTPS fields that apply.
  Derive `noProxy` from the actual topology; do not put destinations in `noProxy` if the design
  requires those requests to traverse Squid.
- Configure the HostedCluster's `spec.configuration.proxy` before or during creation so the installed
  NodePool workers retain the intended proxy settings. Since the Squid listener is plain HTTP on
  port 8213, configure the HTTPS proxy field with an HTTP URL and the proxy's literal IP, for example:
  `httpsProxy: http://<BARE_METAL_PROXY_IP>:8213`. This tells workers to send HTTPS requests through
  Squid; it does not mean workers resolve the destination hostname themselves. Verify the rendered
  worker configuration and rollout behavior; discovery-time proxy configuration alone is not enough.
- Reuse the Squid instance established by the existing baremetal/dev-scripts proxy setup if the
  Nutanix worker network can reach it. The existing `hypershift-agent-create-proxy` step adjusts
  Squid's rules and the CI-side `nested_kubeconfig`; it does not configure the worker InfraEnv. Keep
  these responsibilities explicit rather than assuming the kubeconfig proxy also proxies Agents.
- Determine actual Assisted Service, discovery image/rootfs, hosted API, ignition, Konnectivity,
  OAuth/OIDC, registry, and test dependency hostnames and ports from the generated resources and
  worker configuration. Extend Squid's domain ACL and TLS CONNECT port allowlist only for those
  observed destinations/ports; account for any NodePorts used by the HostedCluster.
- The proxy endpoint is configured as a literal baremetal-host IP, so Nutanix workers do not need a
  DNS record to locate Squid. For HTTPS requests sent through `httpsProxy`, the client sends the
  destination hostname in the HTTP CONNECT request and Squid performs DNS resolution and connects to
  that destination. Verify DNS resolution and routing from the Squid host to each observed endpoint.
- Worker-side DNS is still required for destinations bypassed by `noProxy`, and for any component
  that does not honor the configured proxy. Determine those cases from the actual worker configuration
  and topology. Add DNS records or forwarders only when a concrete missing lookup is demonstrated; do
  not invent service names or duplicate existing records.
- If any endpoint uses a private CA, provide its correct trust bundle to both the discovery
  environment and installed guest configuration. A proxy tunnel does not replace certificate trust;
  do not disable TLS verification or introduce TLS interception.
- Remove run-specific Squid ACL entries in cleanup where they are dynamically added, and avoid stale
  entries or broad allow-all rules.

Before full conformance, boot at least one VM on the actual leased Nutanix subnet and verify:

1. The VM can connect to the configured Squid IP and listener port (normally TCP 8213); no DNS lookup
   is needed for the proxy address when it is configured as a literal IP.
2. Squid accepts CONNECT to each required endpoint and exact port, including the InfraEnv/Assisted
   Service endpoints and hosted API/ignition/Konnectivity endpoints.
3. The discovery Agent registers with the intended InfraEnv/namespace and the installed worker
   retains the intended proxy configuration.
4. Squid resolves and reaches proxied destinations; worker DNS works for any `noProxy`/direct
   destinations. Certificates, routes, firewall policy, and required registry access work through the
   selected paths.

Testing from the CI pod alone is insufficient: the discovery ISO boots in a Nutanix VM with a
different network path. Treat worker-to-proxy reachability as a gate; do not assume it from the
existence of Squid or the success of the ISO download.

### 7. Preserve the hosted ingress and conformance design

- Reuse the hosted API and guest-ingress design from the agreed Agent/vSphere plan, replacing any
  vSphere-specific network, address reservation, or provider assumptions with Nutanix-specific
  values.
- If guest ingress uses MetalLB with HostNetwork router publishing, reserve a VIP on a network
  reachable by the Nutanix workers and test that the Nutanix network supports the required L2
  advertisement. Otherwise choose a supported routed or external load-balancer design before
  conformance.
- Run the existing `hypershift-conformance` chain only after all three guest Nodes are Ready and
  required API/ingress paths have been verified.
- Keep any future workflow/job wiring opt-in and informational until the individual Nutanix steps
  have been rehearsed; this plan does not modify a CI workflow now.

### 8. Cleanup and failure handling

- Gather management/guest diagnostics, Agent/InfraEnv/NodePool state, VM UUID/name/MAC data, and
  relevant Squid/proxy logs before deleting resources.
- Destroy the HostedCluster while the management cluster remains available.
- Deprovision only VM UUIDs and the uploaded image UUID recorded for this run. Do not delete VMs by a
  broad subnet, cluster, or name-prefix query without matching the run's ownership records.
- Remove run-owned NMStateConfig resources and dynamic Squid ACL entries if created.
- Release the Nutanix lease after its VMs/images and run-owned configuration have been removed.
- Tear down the management cluster and release its existing allocation last.
- Make cleanup best-effort and safe after partial lease acquisition, failed ISO download, partial VM
  creation, or failed Agent registration. A Nutanix cleanup failure must not suppress management
  cleanup or diagnostic collection.

## Validation and acceptance criteria

- [ ] Preserve the existing management `cluster_profile` and prove separate Nutanix lease acquisition,
  credential mounts, and release work without clobbering management lease context.
- [ ] Validate Nutanix subnet DHCP availability and worker-to-worker/management/proxy routing before
  full installation. Exercise `NMStateConfig` as a separate fallback if the subnet lacks DHCP.
- [ ] Prove one InfraEnv-generated discovery ISO boots a Nutanix VM and registers an Agent in the
  intended namespace without standalone installer ISO mutation or rendezvous configuration.
- [ ] Verify the Nutanix Ansible path creates only the three worker VMs, preserves the 8-vCPU/16-GB/
  120-GB baseline, captures their UUIDs, and attaches/boots the ISO as intended.
- [ ] Verify run-scoped Agent selection, approval of only the expected three Agents, NodePool scale
  from zero to three, and three Ready guest Nodes.
- [ ] Verify discovery and installed workers use the intended Squid proxy, Squid-side DNS for tunneled
  destinations, worker-side DNS for any `noProxy`/direct destinations, ACL destinations and ports,
  and trust bundle from the actual Nutanix network.
- [ ] Verify hosted API, ignition/Konnectivity as used by the HostedCluster, guest ingress, registries,
  and conformance dependencies are reachable.
- [ ] Run the existing guest conformance and diagnostics chains without changing the standalone
  `agent-qe-nutanix` flow.
- [ ] Rehearse failures during lease acquisition, InfraEnv image creation, ISO upload, partial VM
  creation, Agent registration, and NodePool installation; verify scoped cleanup and retained logs.
- [ ] Verify successful and failed runs leave no Nutanix VMs/images, run-specific DNS/Squid entries,
  or leases behind.

Implement incrementally: validate both leases and the Nutanix worker subnet; prove proxy reachability
from a Nutanix VM; boot one InfraEnv-discovered Agent; then expand to three workers and conformance.
