# Mock KMS Plugin for OpenShift CI Testing

This directory contains reusable step-registry components for deploying and testing KMS v2 encryption in OpenShift CI jobs. The mock plugin is based on the reference implementation from [kubernetes/kubernetes](https://github.com/kubernetes/kubernetes/tree/master/staging/src/k8s.io/kms/internal/plugins/_mock).

## Overview

The mock KMS plugin allows testing of Kubernetes KMS v2 encryption without requiring external KMS infrastructure (AWS KMS, Azure Key Vault, etc.). It's designed for CI/CD testing of apiserver operators and encryption controllers.

## Components

### Steps

- **kms-mock-plugin-deploy**: Deploys the mock KMS v2 plugin as a DaemonSet on control plane nodes
- **kms-mock-plugin-configure**: Configures kube-apiserver to use KMS v2 encryption
- **kms-mock-plugin-cleanup**: Removes the KMS plugin and related resources (post phase)

### Chain

- **kms-mock-plugin-provision**: Combines deploy + configure steps for convenience

## Architecture

The implementation uses a **DaemonSet approach** which is:
- **Platform-agnostic**: Works on AWS, GCP, Azure, and any other platform
- **Fast**: No node reboots required, plugin starts in ~2-3 minutes
- **Simple**: Standard Kubernetes resources, no custom manifests
- **Realistic**: Similar to how real KMS plugins are deployed in production

### How It Works

1. **Init Container**: Builds the mock KMS plugin from kubernetes/kubernetes repo
2. **Main Container**: Runs the plugin listening on `/var/run/kmsplugin/socket.sock`
3. **HostPath Mount**: Exposes the socket to the host so kube-apiserver can access it
4. **DaemonSet**: Ensures the plugin runs on all control plane nodes for HA

## Usage

### Option 1: Use OTE Pattern (Recommended)

Use `openshift-e2e-test` ref with `TEST_SUITE` environment variable:

```yaml
tests:
- as: e2e-aws-operator-encryption-kms
  steps:
    cluster_profile: aws
    env:
      TEST_SUITE: openshift/cluster-kube-apiserver-operator/encryption/kms
    test:
    - chain: kms-mock-plugin-provision
    - ref: openshift-e2e-test
    post:
    - ref: kms-mock-plugin-cleanup
    workflow: ipi-aws
```

### Option 2: Use Custom Commands

For custom test logic not in openshift-tests:

```yaml
tests:
- as: e2e-aws-operator-encryption-kms
  steps:
    cluster_profile: aws
    test:
    - chain: kms-mock-plugin-provision
    - as: run-tests
      cli: latest
      commands: |
        # Run your custom tests
        go test ./test/e2e-encryption-kms/... -v
      from: src
    post:
    - ref: kms-mock-plugin-cleanup
    workflow: ipi-aws
```

### Option 3: Multi-Platform Testing

Test on different platforms by changing cluster_profile and workflow:

```yaml
tests:
- as: e2e-aws-operator-encryption-kms
  cluster_profile: aws
  workflow: ipi-aws
  # ... rest of config

- as: e2e-gcp-operator-encryption-kms
  cluster_profile: gcp
  workflow: ipi-gcp
  # ... rest of config
```

## Testing Workflow

1. **Cluster Installation**: Standard IPI workflow installs the cluster
2. **Deploy Plugin**: DaemonSet deploys and builds the KMS plugin on control plane nodes
3. **Configure Encryption**: APIServer is configured to use KMS v2 for secrets encryption
4. **Run Tests**: Your e2e tests execute against the KMS-encrypted cluster
5. **Cleanup**: Plugin namespace is removed in post phase

## Socket Path

The KMS plugin listens on: `unix:///var/run/kmsplugin/socket.sock`

This path is saved to `${SHARED_DIR}/kms-plugin-socket-path` for use by other steps.

## Example: Full Integration Test

```yaml
- as: e2e-aws-operator-encryption-kms
  optional: true
  run_if_changed: ^(vendor/github.com/openshift/library-go/pkg/operator/encryption)|^(test/e2e-encryption)
  steps:
    cluster_profile: aws
    env:
      TEST_SUITE: openshift/cluster-kube-apiserver-operator/encryption/kms
    test:
    - chain: kms-mock-plugin-provision
    - ref: openshift-e2e-test
    post:
    - ref: kms-mock-plugin-cleanup
    workflow: ipi-aws
```

## Troubleshooting

### Check Plugin Status

```bash
# List KMS plugin pods
oc get pods -n openshift-kms-plugin -l app=kms-plugin

# Check pod logs
oc logs -n openshift-kms-plugin -l app=kms-plugin

# Verify socket exists
oc exec -n openshift-kms-plugin <pod-name> -- ls -la /var/run/kmsplugin/
```

### Check Encryption Status

```bash
# Check kube-apiserver encryption status
oc get kubeapiserver cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")]}'

# Check APIServer configuration
oc get apiserver cluster -o yaml
```

### Common Issues

1. **Plugin fails to build**: Check init container logs for build errors
2. **Socket not accessible**: Verify hostPath permissions and DaemonSet node selector
3. **Encryption migration stuck**: Check kube-apiserver operator logs
4. **Timeout waiting for pods**: Increase timeout or check cluster resources

## Benefits Over MachineConfig Approach

- ✅ **No node reboots**: DaemonSet starts instantly
- ✅ **Platform-agnostic**: Works on all cloud providers and bare metal
- ✅ **Faster**: ~2-3 minutes vs ~10-15 minutes with MachineConfig
- ✅ **Easier to debug**: Standard pod logs and kubectl commands
- ✅ **Better resource usage**: Only runs on control plane nodes

## Related Issues

- Enhancement Proposal: https://github.com/openshift/enhancements/pull/1900
- JIRA Ticket: CNTRLPLANE-2247
