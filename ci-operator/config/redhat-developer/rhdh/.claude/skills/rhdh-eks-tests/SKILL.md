---
name: rhdh-eks-tests
description: >-
  List EKS test entries in RHDH ci-operator config files and update the EKS
  Kubernetes version in the shared MAPT create script
allowed-tools: Read, Edit, Bash(bash *list-k8s-test-configs.sh*)
---
# RHDH EKS Test Management

List EKS test entries and update the K8s version used by EKS MAPT clusters.

## When to Use

- List which EKS test entries exist per RHDH release branch
- Update the EKS K8s version after a lifecycle check
- The version lives in a shared step-registry script — changes affect ALL branches

## Prerequisites

- `yq` (v4+) for listing tests

## Listing Tests

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/list-k8s-test-configs.sh" \
  --pattern "^e2e-eks-" \
  --mapt-script ci-operator/step-registry/redhat-developer/rhdh/eks/mapt/create/redhat-developer-rhdh-eks-mapt-create-commands.sh
```

Filter by branch: add `--branch main`.

## Updating the Version

The K8s version is the `--version X.Y` flag in the MAPT create script:

```
ci-operator/step-registry/redhat-developer/rhdh/eks/mapt/create/redhat-developer-rhdh-eks-mapt-create-commands.sh
```

To update, use the `Edit` tool to replace the `--version` value in that file. Verify the MAPT image tag in the corresponding ref YAML is compatible with the new K8s version:

```
ci-operator/step-registry/redhat-developer/rhdh/eks/mapt/create/redhat-developer-rhdh-eks-mapt-create-ref.yaml
```

**WARNING**: This change affects ALL RHDH branches. `make update` is NOT required.

## Related Skills

- **`rhdh-eks-lifecycle`**: Check which K8s versions are supported before updating
