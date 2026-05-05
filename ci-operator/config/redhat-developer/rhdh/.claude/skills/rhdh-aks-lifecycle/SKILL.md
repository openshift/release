---
name: rhdh-aks-lifecycle
description: >-
  Check AKS Kubernetes version support status and compare against the
  configured version in the CI config files
allowed-tools: Bash(bash *check-k8s-lifecycle.sh*), WebFetch
---
# Check AKS Kubernetes Version Lifecycle

## When to Use

- Check if the configured AKS K8s version is still supported
- Find the newest GA version available on AKS
- Before updating the AKS K8s version (use `rhdh-aks-tests` to make changes)

## Prerequisites

- `curl`, `jq`, `yq` (v4+), internet connectivity

## Steps

1. Run the lifecycle check script:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-k8s-lifecycle.sh" \
  --api-url https://endoflife.date/api/azure-kubernetes-service.json \
  --mapt-ref ci-operator/step-registry/redhat-developer/rhdh/aks/mapt/create/redhat-developer-rhdh-aks-mapt-create-ref.yaml \
  --test-pattern "^e2e-aks-"
```

2. Cross-verify by fetching the vendor docs and comparing supported versions:

```
WebFetch https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions
```

Report any discrepancies between endoflife.date and the vendor page.

## Related Skills

- **`rhdh-aks-tests`**: Update the AKS K8s version and list test entries
