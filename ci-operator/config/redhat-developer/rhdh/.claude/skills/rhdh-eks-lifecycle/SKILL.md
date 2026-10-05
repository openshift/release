---
name: rhdh-eks-lifecycle
description: >-
  Check EKS Kubernetes version support status using the official AWS EKS docs
  source and compare against versions configured in CI config files. Use
  whenever someone asks about EKS K8s version support, EOL dates, or whether
  the configured EKS version is still in standard support. Also use when
  planning EKS K8s version upgrades — run this before using rhdh-eks-tests to
  make changes.
allowed-tools: Bash(bash *check-eks-lifecycle.sh*), WebFetch
---
# Check EKS Kubernetes Version Lifecycle

## When to Use

- Check if the configured EKS K8s version is still supported
- Find the newest GA version available on EKS
- See which K8s version each RHDH release branch is using for EKS tests
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

```text
WebFetch https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
```

## Interpreting Results

The script outputs four sections:

1. **Configured MAPT_KUBERNETES_VERSION per branch** — shows what each RHDH release branch is currently using. If a version shows "N/A", the test entry may be missing the env var.

2. **Supported minor versions** — lists versions with their support tier:
   - **Standard**: actively supported, receives patches and security updates
   - **Extended**: past standard support end date but still receives critical patches (at additional cost on AWS)
   - Prefer Standard-tier versions for CI tests to avoid extended support costs and align with upstream

3. **Release calendar** — shows upstream release date, EKS release date, and end dates for both standard and extended support. Use this to plan ahead for upcoming EOL dates.

4. **Cross-verify (endoflife.date)** — independent EOL and extended support dates. If these disagree with the primary source, investigate further before making changes.

## Action

**Always update the main branch to the newest Standard version.** If the configured version on main is not the newest Standard version, proceed to update it using the `rhdh-eks-tests` skill to change `MAPT_KUBERNETES_VERSION` in the main CI config file.

For release branches (e.g., release-1.9, release-1.8), **ask the user** whether they should also be updated before making changes.

## Related Skills

- **`rhdh-eks-tests`**: Update the EKS K8s version and list test entries
