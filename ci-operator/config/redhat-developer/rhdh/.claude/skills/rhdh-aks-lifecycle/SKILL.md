---
name: rhdh-aks-lifecycle
description: >-
  Check AKS Kubernetes version support status using the official AKS release
  status API and compare against the configured version in the CI config files
allowed-tools: Bash(bash *check-aks-lifecycle.sh*), WebFetch
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
bash "${CLAUDE_SKILL_DIR}/scripts/check-aks-lifecycle.sh" \
  --mapt-ref ci-operator/step-registry/redhat-developer/rhdh/aks/mapt/create/redhat-developer-rhdh-aks-mapt-create-ref.yaml \
  --test-pattern "^e2e-aks-"
```

The script queries two sources:
- **Primary**: `https://releases.aks.azure.com/parsed_data.json` — official AKS release status with per-region K8s version availability (major.minor only)
- **Cross-verify**: `https://endoflife.date/api/azure-kubernetes-service.json` — community-maintained EOL dates

2. If the API call fails, fall back to the vendor docs:

```
WebFetch https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions
```

## Related Skills

- **`rhdh-aks-tests`**: Update the AKS K8s version and list test entries
