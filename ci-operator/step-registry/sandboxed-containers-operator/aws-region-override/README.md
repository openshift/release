# Sandboxed Containers Operator - AWS Region Override

This documentation describes how to use the custom AWS region override step for the Sandboxed Containers Operator with OpenShift IPI  workflows.

## Overview

By default, IPI workflows determine the AWS region through the `LEASED_RESOURCE` environment variable, which is set by the cluster profile lease system. The `sandboxed-containers-operator-e2e-aws` workflow was modified to place `sandboxed-containers-operator-aws-region-override` before cluster installation.

## Components

### Core Step: `sandboxed-containers-operator-aws-region-override`

**Location**: `ci-operator/step-registry/sandboxed-containers-operator/aws-region-override/`

**Purpose**: `ipi-conf-aws` creates `install-config.yaml` in the `pre:` step.  `sandboxed-containers-operator-aws-region-override` modifies `install-config.yaml` to use a different AWS region before cluster installation in `ipi-install`

**Environment Variables**:
- `AWS_REGION_OVERRIDE`: Explicit region override (highest priority)
- `AWS_ALLOWED_REGIONS`: Space-separated list of allowed regions for validation/selection

## Usage Patterns

### Pattern 1: Force Specific Region for Sandboxed Containers Testing

```yaml
tests:
- as: aws-ipi-peerpodsgather-must-gather/sandboxed-containers-operator-gather-must-gather-commands.sh gather-must-gather/sandboxed-containers-operator-gather-must-gather-ref.metadata.json gather-must-gather/sandboxed-containers-operator-gather-must-gather-ref.yaml
  steps:
    cluster_profile: aws
    env:
      AWS_REGION_OVERRIDE: us-east-2
      ENABLEPEERPODS: "true"
      EXPECTED_OSC_VERSION: 1.10.0
      EXPECTED_TRUSTEE_VERSION: 0.4.1
      RUNTIMECLASS: kata-remote
      SLEEP_DURATION: "0"
      TEST_FILTERS: ~DisconnectedOnly&;~Disruptive&
      TEST_SCENARIOS: sig-kata.*Kata Author
      TEST_TIMEOUT: "75"
      WORKLOAD_TO_TEST: peer-pods
    workflow: sandboxed-containers-operator-e2e-aws
```

### Pattern 2: Use a Random Region From a Specific List of Regions

```yaml
tests:
- as: aws-ipi-peerpods-random-allowed-region
  steps:
    cluster_profile: aws
    env:
      AWS_ALLOWED_REGIONS: "us-east-1 us-west-2 eu-west-1 ap-southeast-1"
      ENABLEPEERPODS: "true"
      EXPECTED_OSC_VERSION: 1.10.0
      EXPECTED_TRUSTEE_VERSION: 0.4.1
      RUNTIMECLASS: kata-remote
      SLEEP_DURATION: "0"
      TEST_FILTERS: ~DisconnectedOnly&;~Disruptive&
      TEST_SCENARIOS: sig-kata.*Kata Author
      TEST_TIMEOUT: "75"
      WORKLOAD_TO_TEST: peer-pods
    workflow: sandboxed-containers-operator-e2e-aws
```

### Pattern 3: Force a Specific Region From a List

```yaml
tests:
- as: aws-ipi-peerpods-ap-southeast-1
  steps:
    cluster_profile: aws
    env:
      AWS_REGION_OVERRIDE: "ap-southeast-1"
      AWS_ALLOWED_REGIONS: "ap-southeast-1 ap-northeast-1 ap-south-1"
      ENABLEPEERPODS: "true"
      EXPECTED_OSC_VERSION: 1.10.0
      EXPECTED_TRUSTEE_VERSION: 0.4.1
      RUNTIMECLASS: kata-remote
      SLEEP_DURATION: "0"
      TEST_FILTERS: ~DisconnectedOnly&;~Disruptive&
      TEST_SCENARIOS: sig-kata.*Kata Author
      TEST_TIMEOUT: "75"
      WORKLOAD_TO_TEST: peer-pods
    workflow: sandboxed-containers-operator-e2e-aws
```

## Region Selection Priority

The step follows this priority order (highest to lowest):

1. **AWS_REGION_OVERRIDE** - Explicit region override
2. **AWS_ALLOWED_REGIONS** - If leased region not in list, select random from allowed regions
3. **LEASED_RESOURCE** - Use original leased region (no override)

## Prerequisites

### AWS Credentials
- Your AWS credentials (in the cluster profile) must have permissions in the target region
- Ensure sufficient service quotas in the target region for your cluster size

### Cluster Profile Configuration
- Use an appropriate cluster profile (e.g., `aws`, `aws-2`)
- The base domain should be appropriate for the target region

### Dependencies
- Must run **after** a base IPI configuration step (e.g., `ipi-conf-aws`)
- The `install-config.yaml` file must exist in `${SHARED_DIR}`

## What the Step Does

1. **Validates** prerequisites (LEASED_RESOURCE, install-config.yaml exists)
2. **Determines** target region based on priority rules
3. **Modifies** install-config.yaml to use the target region
4. **Removes** region-specific availability zones (lets installer choose appropriate ones)
5. **Validates** the configuration change was successful
6. **Exports** the final region to `${SHARED_DIR}/aws-region`
7. **Sets** `AWS_DEFAULT_REGION` environment variable

## Outputs

- **Modified install-config.yaml**: Updated with target region
- **${SHARED_DIR}/aws-region**: File containing the final region name
- **AWS_DEFAULT_REGION**: Environment variable set for subsequent steps
- **Configuration backup**: `install-config.yaml.backup` for debugging

## Troubleshooting

### Common Issues

1. **"install-config.yaml not found"**
   - Ensure the region override step runs after the base IPI configuration step
   - Check that `ipi-conf-aws` or similar step runs first

2. **"Region not in allowed list"**
   - Verify the `AWS_REGION_OVERRIDE` value is in `AWS_ALLOWED_REGIONS`
   - Check for typos in region names

3. **AWS permissions errors**
   - Ensure AWS credentials have permissions in the target region
   - Verify the cluster profile has access to the target region

4. **Quota exceeded errors**
   - Check AWS service quotas in the target region
   - Request quota increases if needed, especially for specialized instance types

5. **Instance type not available**
   - Verify the target region supports required instance types for sandboxed containers
   - Consider using `AWS_ALLOWED_REGIONS` to restrict to known working regions

### Debugging

The step provides detailed logging including:
- Original vs target region
- Configuration changes (diff output)
- Validation results
- Final region selection
- Sandboxed containers-specific considerations

Check the step logs for detailed information about the region override process.

## Limitations

1. **AWS Credentials**: Must be valid for the target region
2. **Service Quotas**: Target region must have sufficient quotas
3. **Instance Types**: Target region must support required instance types for sandboxed containers
4. **VPC/Networking**: If using existing VPC, it must exist in target region
5. **DNS Configuration**: Base domain may need to be region-appropriate
6. **Availability Zones**: Hardcoded zones are removed; installer selects appropriate ones

## Recommended AWS Regions for Sandboxed Containers

Based on feature availability and instance type support:

### Primary Regions (Best Support)
- **us-east-1** (N. Virginia) - Full feature set, all instance types
- **us-west-2** (Oregon) - Full feature set, good for West Coast teams
- **eu-west-1** (Ireland) - Full feature set, good for European teams

### Secondary Regions (Good Support)
- **us-east-2** (Ohio) - Good support, alternative to us-east-1
- **eu-central-1** (Frankfurt) - Good European alternative
- **ap-southeast-1** (Singapore) - Good for Asia-Pacific teams

### Regional Codes Reference
- **US**: `us-east-1`, `us-east-2`, `us-west-1`, `us-west-2`
- **EU**: `eu-west-1`, `eu-west-2`, `eu-west-3`, `eu-central-1`, `eu-north-1`
- **Asia Pacific**: `ap-southeast-1`, `ap-southeast-2`, `ap-northeast-1`, `ap-northeast-2`, `ap-south-1`
- **Other**: `ca-central-1`, `sa-east-1`

## Testing

To test the region override with sandboxed containers:

1. Create a test job with the region override configuration
2. Check the step logs for successful region change
3. Verify the cluster is created in the expected region
4. Validate that sandboxed containers operator tests pass in the new region
5. Confirm required instance types are available and functional
