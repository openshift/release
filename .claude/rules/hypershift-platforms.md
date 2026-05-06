---
paths:
  - "ci-operator/step-registry/hypershift/gcp/**"
  - "ci-operator/step-registry/hypershift/kubevirt/**"
  - "ci-operator/step-registry/hypershift/agent/**"
  - "ci-operator/step-registry/hypershift/mce/**"
  - "ci-operator/step-registry/hypershift/ibmcloud/**"
  - "ci-operator/step-registry/hypershift/powervs/**"
  - "ci-operator/step-registry/hypershift/openstack/**"
---

# HyperShift Additional Platforms

## GCP

Uses Workload Identity Federation (WIF) for OIDC-based service account authentication. Each hosted cluster component gets its own GCP service account (controlplane, nodepool, cloudcontroller, storage, imageregistry, network).

**Key concepts:**
- **Workload Identity Federation (WIF)**: K8s ServiceAccounts mapped to GCP ServiceAccounts via OIDC — requires pool ID, provider ID, project number
- **Private Service Connect (PSC)**: Secure API server access without public endpoints
- RHCOS boot image pinned to specific version (default: `projects/rhcos-cloud/global/images/rhcos-*`)

**Setup chain**: `hypershift-gcp-control-plane-setup` → `hypershift-gcp-hosted-cluster-setup` → `hypershift-gcp-create`

**SHARED_DIR artifacts**: `gcp-region`, `hosted-cluster-project-id`, `control-plane-project-id`, `wif-pool-id`, `wif-provider-id`, `wif-project-number`, per-SA files (`controlplane-sa`, `nodepool-sa`, etc.), `sa-signing-key-path`

**Cluster profile**: `hypershift-gcp`

## KubeVirt

Nested virtualization model: KubeVirt VMs run as pods on the management cluster. The management cluster provides the compute, storage, and networking substrate.

**Hosting layers**: bare metal, AWS, or Azure
**Requires**: CNV (Container-native Virtualization) operator subscription

**Key env vars:**

| Variable | Default | Purpose |
|---|---|---|
| `HYPERSHIFT_NODE_MEMORY` | 16Gi | Memory per VM |
| `HYPERSHIFT_NODE_CPU_CORES` | 4 | CPU cores per VM |
| `KUBEVIRT_CSI_INFRA` | | Storage class for KubeVirt CSI driver |
| `ATTACH_DEFAULT_NETWORK` | | Network attachment (true/false) |
| `IP_STACK` | v4 | Networking: v4, v6, or v4v6 (dual-stack) |
| `CNV_SUBSCRIPTION_SOURCE` | redhat-operators | CNV operator source |
| `DISCONNECTED` | false | Air-gapped/disconnected mode |

**Credentials**: `/etc/cnv-nightly-pull-credentials`, `/var/run/cnv-ci-brew-pull-secret/token`

**Subdirectories**: create/, install/, conformance/, e2e-nested/, run-e2e-local/, run-e2e-external/, destroy/, csi-e2e/

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

**SHARED_DIR artifacts**: `hosts.yaml` (BareMetalHost definitions), `packet-conf.sh`, `proxy-conf.sh`, `hostedcluster_name`

## MCE (Multicluster Engine)

MCE provides lifecycle management for HyperShift hosted clusters. `MCE_VERSION` (2.4-2.10) controls behavior — version 2.6+ uses IAM roles, <2.6 uses direct credentials.

**Supported sub-platforms:**
- `mce/aws/` — MCE on AWS
- `mce/agent/` — Agent-based with AgentServiceConfig CR
- `mce/kubevirt/` — MCE with KubeVirt
- `mce/power/` — IBM Power Systems
- `mce/ibmz/` — IBM Z (s390x)

**Key env vars:**
- `MCE_VERSION`: MCE release version (2.4, 2.5, ..., 2.10)
- `HYPERSHIFT_CP_AVAILABILITY_POLICY`: SingleReplica or HighlyAvailable
- `OVERRIDE_CPO_IMAGE`: Custom control plane operator image
- `KONFLUX_DEPLOY_CATALOG_SOURCE`, `KONFLUX_DEPLOY_OPERATORS`: Konflux build flags

**MCE agent workflow**: AgentServiceConfig CR orchestrates bare metal provisioning with LVM storage, MinIO for S3-compatible backup

**Additional subdirectories**: install/, upgrade/, dump/, conf-os-images/, multi-version-test/

## Cluster Profile Summary

| Profile | Platform |
|---|---|
| `hypershift-aws` | AWS |
| `hypershift-azure` | Azure self-managed (OpenShift management clusters) |
| `hypershift-aks` | Azure managed / ARO-HCP (AKS management cluster) |
| `hypershift-gcp` | GCP with Workload Identity Federation |
| `hypershift-powervs` | IBM Power Systems |
| `equinix-ocp-hcp` | Agent / bare metal (MCE) |
