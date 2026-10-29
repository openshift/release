---
paths:
  - "ci-operator/step-registry/hypershift/gcp/**"
  - "ci-operator/step-registry/hypershift/kubevirt/**"
  - "ci-operator/step-registry/hypershift/agent/**"
  - "ci-operator/step-registry/hypershift/mce/**"
---

# HyperShift Additional Platforms

## GCP

Uses Workload Identity Federation (WIF) for OIDC-based service account authentication. Each hosted cluster component gets its own GCP service account (controlplane, nodepool, cloudcontroller, storage, imageregistry, network).

**Key concepts:**
- **Workload Identity Federation (WIF)**: K8s ServiceAccounts mapped to GCP ServiceAccounts via OIDC — requires pool ID, provider ID, project number
- **Private Service Connect (PSC)**: Secure API server access without public endpoints
- RHCOS boot image pinned to specific version (default: `projects/rhcos-cloud/global/images/rhcos-9-6-20250925-0-gcp-x86-64`)

**Setup steps**: `hypershift-gcp-control-plane-setup` (ref) and `hypershift-gcp-hosted-cluster-setup` (ref) are individual pre-steps in the `hypershift-gcp-gke-e2e-v2` workflow, followed by the `hypershift-gcp-create` chain

**SHARED_DIR artifacts**: `gcp-region`, `hosted-cluster-project-id`, `control-plane-project-id`, `wif-pool-id`, `wif-provider-id`, `wif-project-number`, per-SA files (`controlplane-sa`, `nodepool-sa`, etc.), `sa-signing-key-path`

**Management cluster**: GKE Autopilot (not an OpenShift cluster). The `gke/` subdirectory contains provision, prerequisites, deprovision, and e2e workflows.

**Important subdirectories**: control-plane-setup/, hosted-cluster-setup/, create/, destroy/, run-e2e/, gke/

**Cluster profile**: `hypershift-gcp`

## KubeVirt

Nested virtualization model: KubeVirt VMs run as pods on the management cluster. The management cluster provides the compute, storage, and networking substrate.

**Hosting layers**: bare metal, AWS, or Azure
**Requires**: CNV (Container-native Virtualization) operator subscription

**Key env vars:**

| Variable | Default | Purpose |
|---|---|---|
| `HYPERSHIFT_NODE_MEMORY` | 16 | Memory per VM (unit Gi is implicit) |
| `HYPERSHIFT_NODE_CPU_CORES` | 4 | CPU cores per VM |
| `KUBEVIRT_CSI_INFRA` | | Storage class for KubeVirt CSI driver |
| `ATTACH_DEFAULT_NETWORK` | | Network attachment (true/false) |
| `IP_STACK` | v4 | Networking: v4, v6, or v4v6 (dual-stack) |
| `CNV_SUBSCRIPTION_SOURCE` | cnv-prerelease-catalog-source | CNV operator source |
| `DISCONNECTED` | false | Air-gapped/disconnected mode |

**Credentials**: `/etc/cnv-nightly-pull-credentials`, `/var/run/cnv-ci-brew-pull-secret/token`

**Subdirectories**: create/, install/, conformance/, e2e-nested/, run-e2e-local/, run-e2e-external/, destroy/, csi-e2e/, azure/, baremetalds/, e2e-aws/, e2e-azure/, run-csi-e2e/, gather/, health-check/, custom-capk/, set-crio-permissions/

## Agent (Bare Metal)

Uses Metal3 BareMetalHost resources for worker node management. Deployed on Equinix/Packet infrastructure.

**Create chain steps:**
1. `hypershift-agent-create-config-dns` — DNS configuration
2. `hypershift-agent-create-hostedcluster` — HostedCluster CR
3. `hypershift-agent-create-proxy` — proxy for API access
4. `hypershift-agent-create-add-worker-metal3` — add workers via Metal3
5. `hypershift-agent-create-metallb` — MetalLB load balancing

**Infrastructure env vars:**
- `PACKET_PLAN`: m3.large.x86 (Equinix metal server type)
- `NUM_EXTRA_WORKERS`: 3
- `DEVSCRIPTS_CONFIG`: IP stack, network type, worker resources

**SHARED_DIR artifacts**: `hosts.yaml` (BareMetalHost definitions, lab variant only), `packet-conf.sh`, `proxy-conf.sh`, `hostedcluster_name`

**Subdirectories**: create/, check/, conformance/, destroy/

## MCE (Multicluster Engine)

MCE provides lifecycle management for HyperShift hosted clusters. `MCE_VERSION` (2.4+) controls behavior — on AWS, version 2.6+ uses IAM roles, <2.6 uses direct credentials.

**Supported sub-platforms:**
- `mce/aws/` — MCE on AWS
- `mce/agent/` — Agent-based with AgentServiceConfig CR
- `mce/kubevirt/` — MCE with KubeVirt
- `mce/power/` — IBM Power Systems
- `mce/ibmz/` — IBM Z (s390x)

**Key env vars:**
- `MCE_VERSION`: MCE release version (2.4+)
- `HYPERSHIFT_CP_AVAILABILITY_POLICY`: SingleReplica or HighlyAvailable
- `OVERRIDE_HO_IMAGE`: Custom HyperShift Operator image (MCE install)
- `OVERRIDE_CPO_IMAGE`: Custom control plane operator image (agent create hostedcluster)
- `USE_KONFLUX_CATALOG`: Use Konflux catalog for MCE install (true/false)

**MCE agent workflow**: AgentServiceConfig CR orchestrates bare metal provisioning. LVM storage and MinIO (S3-compatible backup) are configured as separate workflow steps.

**Additional subdirectories**: install/, upgrade/, dump/, conf-os-images/, multi-version-test/

## Cluster Profile Summary

| Profile | Platform |
|---|---|
| `hypershift-aws` | AWS |
| `hypershift-azure` | Azure self-managed (OpenShift management clusters) |
| `hypershift-aks` | Azure managed / ARO-HCP (AKS management cluster) |
| `hypershift-gcp` | GCP with Workload Identity Federation |
| `hypershift-powervs` | IBM Power Systems |
| `equinix-ocp-hcp` | Agent / bare metal |
| `openshift-org-aws` | KubeVirt on AWS |
| `openshift-org-azure` | KubeVirt on Azure |
| `aws-kubevirt` | MCE KubeVirt GPU tests on AWS |
| `openstack-vexxhost` | OpenStack nested conformance |
