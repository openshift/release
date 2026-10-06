---
name: rhdh-aks-lifecycle
description: >-
  Check AKS Kubernetes version support status using the official AKS release
  status API and compare against versions configured in CI config files. Use
  whenever someone asks about AKS K8s version support, EOL dates, deprecation,
  or whether the configured AKS version is still GA. Also use when planning AKS
  K8s version upgrades — run this before using rhdh-aks-tests to make changes.
allowed-tools: Bash(bash *check-aks-lifecycle.sh*), WebFetch
---
# Check AKS Kubernetes Version Lifecycle

## When to Use

- Check if the configured AKS K8s version is still supported
- Find the newest GA version available on AKS
- See which K8s version each RHDH release branch is using for AKS tests
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

```text
WebFetch https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions
```

## Interpreting Results

The script outputs three sections:

1. **Configured MAPT_KUBERNETES_VERSION per branch** — shows what each RHDH release branch is currently using. If a version shows "N/A", the test entry may be missing the env var.

2. **AKS Release Status** — supported minor versions from the official API, marked as GA, LTS, or Preview. The "Recently deprecated" line shows a version that was just removed from support.

3. **Cross-verify (endoflife.date)** — independent EOL dates. If these disagree with the primary source, investigate further before making changes.

## Action

**Always update the main branch to the newest GA version.** If the configured version on main is not the newest GA version, proceed to update it using the `rhdh-aks-tests` skill to change `MAPT_KUBERNETES_VERSION` in the main CI config file.

For release branches (e.g., release-1.9, release-1.8), **ask the user** whether they should also be updated before making changes.

## Related Skills

- **`rhdh-aks-tests`**: Update the AKS K8s version and list test entries
