---
paths:
  - "ci-operator/step-registry/hypershift/aws/**"
---

# HyperShift AWS Platform

## Architecture

AWS HyperShift uses the nested management cluster pattern:
1. Root OpenShift cluster (pre-existing, shared)
2. Nested management cluster (ephemeral HostedCluster on root, created per CI job)
3. Guest HostedCluster (the cluster under test, created on the nested management cluster)

Key workflow: `hypershift-aws-e2e-nested`

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

| Mount Path | Purpose |
|---|---|
| `/etc/hypershift-ci-jobs-awscreds/credentials` | HyperShift CI account AWS creds |
| `/etc/hypershift-ci-jobs-awscreds/serviceaccount-signer.private` | SA token signing key |
| `/etc/hypershift-pool-aws-credentials/credentials` | Pool AWS creds for nested tests |
| `/etc/ci-pull-credentials/.dockerconfigjson` | Docker pull secrets |
| `/etc/hypershift-kubeconfig/hypershift-ops-admin.kubeconfig` | Root management cluster kubeconfig |

## OIDC

S3-hosted issuer: `https://hypershift-ci-2-oidc.s3.us-east-1.amazonaws.com/shared-mgmt`

## Key Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `HYPERSHIFT_AWS_REGION` | us-east-1 | AWS region |
| `HYPERSHIFT_HC_ZONES` | us-east-1a | Availability zones for hosted cluster |
| `HYPERSHIFT_ZONES` | us-east-1a,us-east-1b,us-east-1c | AZs for management cluster |
| `HYPERSHIFT_INSTANCE_TYPE` | m5.xlarge | EC2 instance type |
| `HYPERSHIFT_NODE_COUNT` | 3 | Worker node count |
| `ENDPOINT_ACCESS` | Public | Public, PublicAndPrivate, or Private |
| `HYPERSHIFT_DISK_ENCRYPTION` | | Enable disk encryption (reads `aws_kms_key_arn` from SHARED_DIR) |
| `HYPERSHIFT_ETCD_ENCRYPTION` | | Enable etcd encryption (reads `aws_kms_key_arn` from SHARED_DIR) |
| `HYPERSHIFT_SHARED_VPC` | | Use shared VPC account credentials |
| `AWS_MULTI_ARCH` | | Enable multi-architecture testing |
| `HYPERSHIFT_AUTONODE` | | Enable auto node scaling |
| `PUBLIC_ONLY` | | Use only public subnets (requires 4.16+) |
| `HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT` | | Use OCP account for guest infra |

## SHARED_DIR Artifacts

| File | Purpose |
|---|---|
| `aws_kms_key_arn` | KMS key ARN for encryption |
| `hcp-role-arn` | HCP STS role ARN |
| `sts-creds.json` | STS credentials JSON |
| `nested_kubeconfig` | Guest cluster kubeconfig |
| `cluster-name` | Generated cluster name |
| `hypershift_create_cluster_render.yaml` | Rendered cluster manifest (if render-only) |

## Subdirectories

- `create/` — HostedCluster creation chain
- `destroy/` — cleanup operations
- `e2e/` — e2e workflows (nested, external, v2)
- `run-e2e/` — e2e test execution (nested, external)
- `conformance-*` — conformance variants (calico, cilium, proxy)
- `reqserving-e2e/` — request serving isolation tests
- `e2e-backuprestore/` — OADP backup/restore workflows
- `oadp-setup/`, `oadp-destroy/` — OADP lifecycle
- `cluster/` — cluster-level operations
