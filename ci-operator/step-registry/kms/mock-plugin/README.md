# Mock KMS Plugin for Testing

This directory contains reusable step-registry components for deploying a mocked KMS v2 plugin in OpenShift CI jobs. 
The mock plugin is based on the reference implementation from [openshift/kubernetes](https://github.com/openshift/kubernetes/tree/master/staging/src/k8s.io/kms/internal/plugins/_mock).

## Components

### kms-mock-plugin-deploy
Deploys the mock KMS v2 plugin as a DaemonSet on control plane nodes. The plugin:
- Runs on all control plane nodes
- Listens on a Unix socket at `/var/run/kmsplugin/kms.sock`
- Implements the KMS v2 API for encryption/decryption
- Provides in-memory encryption without requiring external KMS infrastructure

### kms-mock-plugin-cleanup
Cleans up the mock KMS plugin resources. Should be used in the `post` phase.

## Usage

### Basic Workflow Example

```yaml
workflow:
  as: my-kms-test
  steps:
    pre:
    - chain: ipi-aws-pre
    - ref: kms-mock-plugin-deploy
    test:
    - ref: my-kms-encryption-tests
    post:
    - ref: kms-mock-plugin-cleanup
    - chain: ipi-aws-post
```

### Environment Variables

#### kms-mock-plugin-deploy
- `KMS_PLUGIN_NAMESPACE`: Namespace to deploy the plugin (default: `kms-plugin-test`)

## How It Works

1. **Deploy Step**:
   - Creates a privileged namespace
   - Deploys a DaemonSet with an init container that:
     - Uses sparse-checkout to fetch only the `_mock` plugin directory from openshift/kubernetes
     - Builds the mock KMS provider binary
   - Runs the mock KMS provider on each control plane node
   - Exposes the KMS socket via hostPath

2. **Your Tests**:
   - Configure kube-apiserver or create EncryptionConfiguration resources
   - Reference the KMS socket path
   - Test encryption/decryption operations

3. **Cleanup Step**:
   - Removes the namespace and all resources

## Troubleshooting

### Check Plugin Status
```bash
oc get pods -n kms-plugin-test -l app=mock-kms-plugin
oc logs -n kms-plugin-test -l app=mock-kms-plugin
```

### Verify Socket Existence
```bash
oc exec -n kms-plugin-test <pod-name> -- ls -la /var/run/kmsplugin/
```

### Check Build Logs
```bash
oc logs -n kms-plugin-test <pod-name> -c build-plugin
```