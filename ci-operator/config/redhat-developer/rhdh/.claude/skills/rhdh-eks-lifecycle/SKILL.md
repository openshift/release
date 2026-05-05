---
name: rhdh-eks-lifecycle
description: >-
  Check EKS Kubernetes version support status using the official AWS EKS docs
  source and compare against the configured version in the CI config files
allowed-tools: Bash(bash *check-eks-lifecycle.sh*), WebFetch
---
# Check EKS Kubernetes Version Lifecycle

## When to Use

- Check if the configured EKS K8s version is still supported
- Find the newest GA version available on EKS
- Before updating the EKS K8s version (use `rhdh-eks-tests` to make changes)

## Prerequisites

- `curl`, `jq`, `yq` (v4+), `awk`, internet connectivity

## Steps

1. Run the lifecycle check script:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-eks-lifecycle.sh" \
  --mapt-ref ci-operator/step-registry/redhat-developer/rhdh/eks/mapt/create/redhat-developer-rhdh-eks-mapt-create-ref.yaml \
  --test-pattern "^e2e-eks-"
```

The script queries two sources:
- **Primary**: `awsdocs/amazon-eks-user-guide` raw AsciiDoc on GitHub — official AWS EKS docs source with standard/extended support status and release calendar
- **Cross-verify**: `https://endoflife.date/api/amazon-eks.json` — community-maintained EOL dates

2. If the API call fails, fall back to the vendor docs:

```
WebFetch https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
```

## Related Skills

- **`rhdh-eks-tests`**: Update the EKS K8s version and list test entries
