---
name: rhdh-eks-lifecycle
description: >-
  Check EKS Kubernetes version support status and compare against the
  configured version in the MAPT create script
allowed-tools: Bash(bash *check-k8s-lifecycle.sh*), WebFetch
---
# Check EKS Kubernetes Version Lifecycle

## When to Use

- Check if the configured EKS K8s version is still supported
- Find the newest GA version available on EKS
- Before updating the EKS K8s version (use `rhdh-eks-tests` to make changes)

## Prerequisites

- `curl`, `jq`, internet connectivity

## Steps

1. Run the lifecycle check script:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-k8s-lifecycle.sh" \
  --api-url https://endoflife.date/api/amazon-eks.json \
  --mapt-script ci-operator/step-registry/redhat-developer/rhdh/eks/mapt/create/redhat-developer-rhdh-eks-mapt-create-commands.sh \
  --mapt-ref ci-operator/step-registry/redhat-developer/rhdh/eks/mapt/create/redhat-developer-rhdh-eks-mapt-create-ref.yaml
```

2. Cross-verify by fetching the vendor docs and comparing supported versions:

```
WebFetch https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
```

Report any discrepancies between endoflife.date and the vendor page.

## Related Skills

- **`rhdh-eks-tests`**: Update the EKS K8s version and list test entries
