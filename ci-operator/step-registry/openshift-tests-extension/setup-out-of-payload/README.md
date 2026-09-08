# Out-of-Payload OTE Extension Setup

This step provides a reusable, parameterized way to set up OpenShift clusters for out-of-payload test extension discovery and execution.

## Problem Statement

Previously, each operator implementing OTE (OpenShift Tests Extension) for out-of-payload testing had to duplicate the same setup logic:

1. Install TestExtensionAdmission CRD
2. Create TestExtensionAdmission CR
3. Create namespace for test extensions
4. Create ImageStream with OTE annotations
5. Wait for ImageStream import
6. Verify the setup

This led to code duplication and made it harder to maintain consistent behavior across different operators.

## Solution

The `openshift-tests-extension-setup-out-of-payload` step provides a single, well-tested implementation that can be parameterized via environment variables for any operator.

## Usage

### Basic Usage in a Workflow Chain

```yaml
chain:
  as: my-operator-test-extension
  steps:
  - ref: openshift-tests-extension-setup-out-of-payload
    env:
    - name: EXTENSION_COMPONENT_NAME
      default: "my-operator"
    - name: EXTENSION_BINARY_PATH
      default: "/usr/bin/my-operator-tests-ext.gz"
  - ref: my-operator-run-tests
  env:
  - name: EXTENSION_IMAGE
    default: ""
    documentation: Container image with the test binary (set by CI via dependency injection)
```

### Environment Variables

#### Required Variables

- **`EXTENSION_COMPONENT_NAME`**: Name of the component being tested (e.g., `"cli-manager-operator"`).
  Used in annotations and resource naming.

- **`EXTENSION_BINARY_PATH`**: Path to the test binary inside the extension container image.
  Example: `"/usr/bin/cli-manager-operator-tests-ext.gz"`

- **`EXTENSION_IMAGE`**: Container image containing the test extension binary.
  Typically set automatically by CI configuration via dependency injection.

#### Optional Variables (with defaults)

- **`EXTENSION_IMAGESTREAM_NAME`**: Name for the ImageStream resource.
  Default: `"${EXTENSION_COMPONENT_NAME}-tests"`

- **`EXTENSION_ADMISSION_NAME`**: Name for the TestExtensionAdmission CR.
  Default: `"${EXTENSION_COMPONENT_NAME}-extensions"`

- **`EXTENSION_NAMESPACE`**: Namespace where the ImageStream will be created.
  Default: `"test-extensions"`

- **`EXTENSION_PERMIT_PATTERN`**: Pattern for the TestExtensionAdmission permit rule.
  Default: `"test-extensions/*"`

- **`EXTENSION_IMAGESTREAM_TAG`**: Tag for the ImageStream.
  Default: `"latest"`

- **`EXTENSION_WAIT_TIMEOUT`**: Timeout in seconds to wait for ImageStream import to complete.
  Default: `"300"` (5 minutes)

- **`EXTENSION_SKIP_CRD_INSTALL`**: Skip TestExtensionAdmission CRD installation if set to `"true"`.
  Useful when the CRD is already installed by a previous step.
  Default: `"false"`

## Real-World Examples

### Example 1: run-once-duration-override-operator

See: `ci-operator/step-registry/run-once-duration-override-operator/test-extension-refactored/`

```yaml
chain:
  as: run-once-duration-override-operator-test-extension-refactored
  steps:
  - ref: openshift-tests-extension-setup-out-of-payload
    env:
    - name: EXTENSION_COMPONENT_NAME
      default: "run-once-duration-override-operator"
    - name: EXTENSION_BINARY_PATH
      default: "/usr/bin/run-once-duration-override-operator-tests-ext.gz"
  - ref: run-once-duration-override-operator-test-extension-refactored-run
```

### Example 2: cli-manager-operator (with extra setup)

See: `ci-operator/step-registry/cli-manager/test-extension-refactored/`

This example shows how to add component-specific setup (krew installation) alongside the shared setup:

```yaml
chain:
  as: cli-manager-test-extension-refactored
  steps:
  - ref: openshift-tests-extension-setup-out-of-payload
    env:
    - name: EXTENSION_COMPONENT_NAME
      default: "cli-manager-operator"
    - name: EXTENSION_BINARY_PATH
      default: "/usr/bin/cli-manager-operator-tests-ext.gz"
  - ref: cli-manager-test-extension-refactored-install-krew  # Component-specific setup
  - ref: cli-manager-test-extension-refactored-run
```

## Migration Guide

To migrate an existing out-of-payload OTE setup to use this shared step:

### Before (Monolithic Step)

```yaml
# my-operator-test-extension-ref.yaml
ref:
  as: my-operator-test-extension
  commands: my-operator-test-extension-commands.sh  # Contains setup + test execution
  dependencies:
  - name: my-operator
    env: EXTENSION_IMAGE
```

```bash
# my-operator-test-extension-commands.sh
#!/bin/bash
# ... 50+ lines of setup code (duplicated across operators) ...
# ... test execution ...
```

### After (Using Shared Step)

```yaml
# my-operator-test-extension-refactored-chain.yaml
chain:
  as: my-operator-test-extension-refactored
  steps:
  - ref: openshift-tests-extension-setup-out-of-payload
    env:
    - name: EXTENSION_COMPONENT_NAME
      default: "my-operator"
    - name: EXTENSION_BINARY_PATH
      default: "/usr/bin/my-operator-tests-ext.gz"
  - ref: my-operator-test-extension-refactored-run
  env:
  - name: EXTENSION_IMAGE
    default: ""
    documentation: Container image (set by CI via dependency injection)
```

```yaml
# my-operator-test-extension-refactored-run-ref.yaml
ref:
  as: my-operator-test-extension-refactored-run
  from: tests
  commands: my-operator-test-extension-refactored-run-commands.sh
  timeout: 3600s
  resources:
    requests:
      cpu: "3"
      memory: 600Mi
```

```bash
# my-operator-test-extension-refactored-run-commands.sh
#!/bin/bash
# Only operator-specific test execution (5-10 lines)
set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH

openshift-tests run "${TEST_SUITE}" --junit-dir="${ARTIFACT_DIR}/junit"
```

### Benefits of Migration

1. **Less duplication**: 50+ lines of setup code replaced with 3 lines of configuration
2. **Easier maintenance**: Bug fixes and improvements benefit all operators
3. **Consistent behavior**: All operators use the same well-tested setup logic
4. **Better documentation**: Centralized documentation of the setup process
5. **Easier onboarding**: New operators can quickly set up OTE testing

## CI Configuration Example

In your `ci-operator/config/<org>/<repo>/<org>-<repo>-<branch>.yaml`:

```yaml
images:
- dockerfile_path: Dockerfile
  to: my-operator

tests:
- as: e2e-aws-operator-serial-ote
  cluster_claim:
    architecture: amd64
    cloud: aws
    owner: openshift-ci
    product: ocp
    timeout: 1h0m0s
    version: "4.18"
  steps:
    test:
    - ref: my-operator-test-extension-refactored  # Use the chain
      dependencies:
      - name: my-operator
        env: EXTENSION_IMAGE
```

## Troubleshooting

### ImageStream import timeout

If you see timeout errors waiting for ImageStream import, try:

1. Check if the image exists: `oc describe imagestream <name> -n test-extensions`
2. Increase timeout: Set `EXTENSION_WAIT_TIMEOUT="600"` for 10 minutes
3. Check image pull secrets if using private registries

### TestExtensionAdmission CRD already exists

This is normal when running multiple OTE jobs on the same cluster. The step handles this gracefully.

If you want to skip CRD installation entirely (because another step installs it), set:
```yaml
env:
- name: EXTENSION_SKIP_CRD_INSTALL
  default: "true"
```

### Tests not discovered by openshift-tests

Verify the ImageStream has the correct annotations:

```bash
oc get imagestreamtag <name>:latest -n test-extensions -o json | jq '.metadata.annotations'
```

Should show:
```json
{
  "testextension.redhat.io/component": "my-operator",
  "testextension.redhat.io/binary": "/usr/bin/my-operator-tests-ext.gz"
}
```

## Related Documentation

- [OpenShift CI Documentation](https://docs.ci.openshift.org/)
- [Step Registry Guide](https://docs.ci.openshift.org/docs/architecture/step-registry/)
- [OTE Documentation](https://docs.ci.openshift.org/docs/architecture/step-registry/#openshift-tests-extensions)

## Contributing

Issues or improvements? Please submit a PR to the [openshift/release](https://github.com/openshift/release) repository.
