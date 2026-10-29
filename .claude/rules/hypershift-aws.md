---
paths:
  - "ci-operator/step-registry/hypershift/aws/**"
---

# HyperShift AWS Platform

## Architecture

Most AWS workflows use a 3-tier nested management cluster pattern:
1. Root OpenShift cluster (pre-existing, shared)
2. Nested management cluster (ephemeral HostedCluster on root, created per CI job)
3. Guest HostedCluster (the cluster under test, created on the nested management cluster)

Key workflow: `hypershift-aws-e2e-nested`

Note: Not all workflows follow the 3-tier model. Exceptions include `hypershift-aws-conformance` and `hypershift-aws-e2e-external` which use `hypershift-setup-root-management-cluster` (2-tier), `hypershift-aws-reqserving-e2e` which uses IPI to provision the management cluster, and `hypershift-aws-conformance-proxy` which uses IPI with proxy (`ipi-aws-pre-proxy`).

## AWS Resources Created

- EC2 instances for NodePools (configurable via `HYPERSHIFT_INSTANCE_TYPE`, default: m5.xlarge)
- VPCs and security groups (or BYO VPC via shared account)
- KMS keys for etcd and disk encryption
- IAM roles and service accounts via STS
- ELBs for API endpoints (Public, PublicAndPrivate, or Private access)
- Auto Scaling Groups for NodePools
- S3 bucket for OIDC issuer

## Cluster Profile

`hypershift-aws`

## Credentials

| File Path | Purpose |
|---|---|
| `/etc/hypershift-ci-jobs-awscreds/credentials` | HyperShift CI account AWS creds |
| `/etc/hypershift-pool-aws-credentials/credentials` | Pool AWS creds for nested tests |
| `/etc/ci-pull-credentials/.dockerconfigjson` | Docker pull secrets |
| `/etc/hypershift-kubeconfig/hypershift-ops-admin.kubeconfig` | Root management cluster kubeconfig (run-e2e/nested only) |
| `/etc/hypershift-additional-pull-secret/.dockerconfigjson` | Additional pull secret for e2e tests (run-e2e/nested, run-e2e/external) |

## OIDC

The S3 OIDC issuer URL (`https://hypershift-ci-2-oidc.s3.us-east-1.amazonaws.com/shared-mgmt`) is configured in the management cluster setup chain (outside `hypershift/aws/` scope). Within `hypershift/aws/`, the e2e tests reference S3 bucket `hypershift-ci-oidc` (via `--e2e.aws-oidc-s3-bucket-name=hypershift-ci-oidc`).

## Key Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `HYPERSHIFT_AWS_REGION` | us-east-1 | AWS region |
| `HYPERSHIFT_HC_ZONES` | us-east-1a | Availability zones for hosted cluster |
| `HYPERSHIFT_INSTANCE_TYPE` | m5.xlarge | EC2 instance type |
| `HYPERSHIFT_NODE_COUNT` | 3 | Worker node count |
| `ENDPOINT_ACCESS` | Public | Public, PublicAndPrivate, or Private |
| `HYPERSHIFT_DISK_ENCRYPTION` | false | Enable disk encryption (reads `aws_kms_key_arn` from SHARED_DIR) |
| `HYPERSHIFT_ETCD_ENCRYPTION` | false | Enable etcd encryption (reads `aws_kms_key_arn` from SHARED_DIR) |
| `HYPERSHIFT_SHARED_VPC` | false | Use shared VPC account credentials |
| `AWS_MULTI_ARCH` | false | Enable multi-architecture testing |
| `HYPERSHIFT_AUTONODE` | false | Enable auto node scaling |
| `PUBLIC_ONLY` | false | Use only public subnets (requires 4.16+) |
| `HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT` | false | Use OCP account for guest infra |
| `HYPERSHIFT_BASE_DOMAIN` | (empty) | Cluster FQDN base domain |
| `HYPERSHIFT_EXTERNAL_DNS_DOMAIN` | (empty) | External DNS domain |
| `HYPERSHIFT_CP_AVAILABILITY_POLICY` | SingleReplica | Control plane availability |
| `HYPERSHIFT_CREATE_CLUSTER_RENDER` | false | Render cluster manifest without creating |
| `ENABLE_ICSP` | false | Enable ImageContentSourcePolicy |
| `HYPERSHIFT_HC_RELEASE_IMAGE` | (empty) | Guest cluster release image override |
| `RUN_UPGRADE_TEST` | false | Enable upgrade tests |
| `TECH_PREVIEW_NO_UPGRADE` | false | Skip upgrades for tech preview |
| `HYPERSHIFT_INFRA_AVAILABILITY_POLICY` | SingleReplica | Infrastructure availability |
| `HYPERSHIFT_NETWORK_TYPE` | (empty) | Cluster SDN provider (OVNKubernetes, or Other for BYO CNI like Calico/Cilium) |
| `EXTRA_ARGS` | (empty) | Additional `hypershift create cluster` arguments |

## SHARED_DIR Artifacts

| File | Purpose |
|---|---|
| `aws_kms_key_arn` | KMS key ARN for encryption |
| `nested_kubeconfig` | Guest cluster kubeconfig |
| `cluster-name` | Generated cluster name |
| `hypershift_create_cluster_render.yaml` | Rendered cluster manifest (if render-only) |
| `management_cluster_kubeconfig` | Management cluster kubeconfig (default KUBECONFIG for run-e2e) |
| `management_cluster_name` | Management cluster name |
| `management_cluster_namespace` | Management cluster namespace |
| `mgmt_icsp.yaml` | Image content source policy |

## Subdirectories

- `create/` — HostedCluster creation chain (includes `nodepool/` for multi-arch)
- `destroy/` — cleanup operations
- `e2e/` — e2e workflows (nested, external, external/oidc, cluster, metrics)
- `e2e-v2/` — v2 e2e workflow
- `run-e2e/` — e2e test execution (nested, external)
- `conformance/` — base AWS conformance workflow
- `conformance-calico/` — Calico conformance variant (uses 3-tier nested model)
- `conformance-cilium/` — Cilium conformance variant (uses 3-tier nested model)
- `conformance-proxy/` — proxy conformance variant
- `reqserving-e2e/` — request serving isolation tests
- `run-reqserving-e2e/` — request serving e2e test execution
- `e2e-backuprestore/` — OADP backup/restore workflows
- `oadp-setup/`, `oadp-destroy/` — OADP lifecycle
- `cluster/` — cluster-level operations
