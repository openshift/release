# Sandboxed Containers Operator - Prowjob Configuration Generator

This directory contains a robust script to generate OpenShift CI prowjob configuration files for the Sandboxed Containers Operator with comprehensive validation and error handling.

## Overview

The `sandboxed-containers-operator-create-prowjob-commands.sh` script creates prowjob configuration files for the sandboxed containers operator CI pipeline. It supports both Pre-GA (development) and GA (production) release types with intelligent catalog source management and comprehensive parameter validation.

## Files

- `sandboxed-containers-operator-create-prowjob-commands.sh` - Main script to generate prowjob configurations
- The output file is created in the current directory and named `openshift-sandboxed-containers-operator-devel__downstream-${PROW_RUN_TYPE}${OCP_VERSION}.yaml`
  - `PROW_RUN_TYPE` is based on ``TEST_RELEASE_TYPE.  It is `candidate` for `Pre-GA` and `release` otherwise
- If the output file exists, it will be moved to a `.backup` file

## Key Features

- Automatically queries Quay API for latest catalog tags
  - If the tag is in X.Y.Z-epoch_time, it is used as the expected version of OSC and Trustee
- Different behavior for Pre-GA vs GA releases
- Generated files are not merged
  - /PJ-REHEARSE in the PR to run prowjobs


## Usage

### Basic Usage

Ensure you are in the __release__ directory of your fork of the [Prow repo](https://github.com/openshift/release)
The script uses environment variables exclusively for configuration:

```bash
# Generate configuration with defaults
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh

# Generate configuration with custom OCP version
OCP_VERSION=4.17 ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh
```

### Environment Variables

| Variable                   | Default Value            | Description                                                                 | Validation               |
| -------------------------- | ------------------------ | --------------------------------------------------------------------------- | ------------------------ |
| `OCP_VERSION`              | `4.19`                   | OpenShift Container Platform version                                        | Format: X.Y (e.g., 4.19) |
| `AWS_REGION_OVERRIDE`      | `us-east-2`              | AWS region for testing                                                      | Any valid AWS region     |
| `CUSTOM_AZURE_REGION`      | `eastus`                 | Azure region for testing                                                    | Any valid Azure region   |
| `OSC_CATALOG_TAG`          | derived latest           | Can be overridden.  Also sets EXPECTED_OSC_VERSION                          | repo tag                 |
| `TRUSTEE_CATALOG_TAG`      | derived latest           | Can be overridden.  Also sets EXPECTED_TRUSTEE_VERSION                      | repo tag                 |
| `EXPECTED_OSC_VERSION`     | `1.10.1`                 | Derived from X.Y.X-epoch_time catalog tag or OSC_CATALOG_TAG                | Semantic version format  |
| `EXPECTED_TRUSTEE_VERSION` | `0.4.1`                  | Derived from X.Y.X-epoch_time catalog tag IFF exists or TRUSTEE_CATALOG_TAG | Semantic version format  |
| `INSTALL_KATA_RPM`         | `true`                   | Whether to install Kata RPM                                                 | `true` or `false`        |
| `KATA_RPM_VERSION`         | `3.17.0-3.rhaos4.19.el9` | Kata RPM version (when `INSTALL_KATA_RPM=true`)                             | RPM version format       |
| `PROW_RUN_TYPE`            | `candidate`              | Prow job run type                                                           | `candidate` or `release` |
| `SLEEP_DURATION`           | `0h`                     | Time to keep cluster alive after tests                                      | 0-12 followed by 'h'     |
| `TEST_RELEASE_TYPE`        | `Pre-GA`                 | Release type for testing                                                    | `Pre-GA` or `GA`         |
| `TEST_TIMEOUT`             | `90`                     | Test timeout in minutes                                                     | Numeric value            |

### Pre-GA vs GA Configuration

#### Pre-GA (Development) Mode
- Automatically queries Quay API for latest OSC catalog tags of development branch
  - OSC searches for X.Y.Z-epoch_time tag
  - trustee uses an algorhythm
- Creates `brew-catalog` and `trustee-catalog` sources with latest catalog tag
  - if catalog tag is X.Y.Z-, the expected version of the operator is set

#### GA (Production) Mode
- Uses `redhat-operators` catalog source with GA images

### Advanced Configuration Examples

#### Pre-GA Development Testing
```bash
# Test latest development builds
TEST_RELEASE_TYPE=Pre-GA \
PROW_RUN_TYPE=candidate \
OCP_VERSION=4.18 \
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh
```

#### GA Production Testing
```bash
# Test production releases
TEST_RELEASE_TYPE=GA \
PROW_RUN_TYPE=release \
OCP_VERSION=4.19 \
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh
```

#### Custom Regions and Timeouts
```bash
# Extended testing with custom regions
AWS_REGION_OVERRIDE=us-west-2 \
CUSTOM_AZURE_REGION=westus2 \
SLEEP_DURATION=2h \
TEST_TIMEOUT=120 \
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh
```

#### Kata RPM Testing
```bash
# Test without Kata RPM installation
INSTALL_KATA_RPM=false \
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh

# Test with specific Kata RPM version
INSTALL_KATA_RPM=true \
KATA_RPM_VERSION=3.18.0-3.rhaos4.20.el9 \
ci-operator/step-registry/sandboxed-containers-operator/create-prowjob/sandboxed-containers-operator-create-prowjob-commands.sh
```

## Catalog Tag Discovery

### OSC Catalog Tags
- **Pattern**: `X.Y[.Z]-epoch_time` (e.g., `1.10.1-1755502791`, `1.10-1234567890`)
- **Source**: `quay.io/redhat-user-workloads/ose-osc-tenant/osc-test-fbc`
- **Method**: Quay API with pagination (max 20 pages)
- **Fallback**: `1.10.1-1755502791`

### Trustee Catalog Tags
- **Pattern**: `trustee-fbc-{OCP_VER}-on-push-.*-build-image-index`
- **Source**: `quay.io/redhat-user-workloads/ose-osc-tenant/[trustee-fbc/]trustee-fbc-{OCP_VER}`
- **Method**: Quay API with pagination (max 50 pages)
- **Special Case**: OCP 4.16 uses `trustee-fbc/` subfolder

## Generated Test Matrix

The script generates configuration for 5 test scenarios:

1. **azure-ipi-kata**: Azure kata
2. **azure-ipi-peerpods**: Azure peer-pods
3. **azure-ipi-coco**: Azure coco
4. **aws-ipi-peerpods**: AWS peer-pods
5. **aws-ipi-coco**: AWS coco

Each test includes:
- Appropriate cloud provider configuration
- Catalog source settings based on release type
- Runtime class configuration
- Environment-specific parameters

## Output and Next Steps

### Generated Files
- **File Name**: `openshift-sandboxed-containers-operator-devel__downstream-{PROW_RUN_TYPE}{OCP_VERSION}.yaml`
- **Location**: Current directory
- **Backup**: Existing files are backed up with `.backup` extension

### Deployment Process
1. **Review** the generated configuration:
   ```bash
   cat openshift-sandboxed-containers-operator-devel__downstream-candidate4.19.yaml
   ```

2. **Move** to the appropriate directory:
   ```bash
   mv openshift-sandboxed-containers-operator-devel__downstream-candidate4.19.yaml \
      ci-operator/config/openshift/sandboxed-containers-operator/
   ```
_Things will not compile with files in the wrong location_

3. **Generate** CI configuration:
   ```bash
   make ci-operator-config && make registry-metadata && make prow-config && make jobs && make update
   ```

## Validation and Error Handling

The script includes comprehensive validation:

- **Parameter Format**: Validates version formats, boolean values, numeric ranges
- **API Connectivity**: Tests Quay API availability and response validity
- **File Operations**: Checks file creation, YAML syntax (when `yq` available)
- **Configuration Logic**: Ensures consistent catalog source configuration

### Common Error Scenarios
- **Invalid OCP_VERSION**: Must be in X.Y format
- **Invalid SLEEP_DURATION**: Must be 0-12 followed by 'h'
- **API Failures**: Network issues or catalog tag discovery failures
- **File Conflicts**: Existing file backup and overwrite handling

## Troubleshooting

### Catalog Tag Discovery Issues
```bash
# Test connectivity to Quay API
curl -sf "https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/osc-test-fbc/tag/?limit=10&page=1"

# Check for matching tags manually
curl -s "https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/osc-test-fbc/tag/" | \
  jq '.tags[] | select(.name | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?-[0-9]+$")) | .name'
```

### YAML Validation
```bash
# Install yq for validation
# On macOS: brew install yq
# On Linux: Download from https://github.com/mikefarah/yq/releases

# Validate generated YAML
yq eval '.' openshift-sandboxed-containers-operator-devel__downstream-candidate4.19.yaml
```

## Dependencies

- **Required**: `curl`, `jq`, `awk`, `sort`, `head`
- **Optional**: `yq` (for YAML syntax validation)
- **Network**: Access to `quay.io` API endpoints
