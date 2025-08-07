# Sandboxed Containers Operator - AWS Region Override

This documentation describes how to use the custom AWS region override step for the Sandboxed Containers Operator with OpenShift IPI (Installer Provisioned Infrastructure) workflows.

## Overview

By default, IPI workflows determine the AWS region through the `LEASED_RESOURCE` environment variable, which is set by the cluster profile lease system. This custom step allows the Sandboxed Containers Operator to override that region selection with flexible configuration options, enabling testing in specific AWS regions where sandboxed containers and confidential computing features are best supported.

## Components

### Core Step: `sandboxed-containers-operator-aws-region-override`

**Location**: `ci-operator/step-registry/sandboxed-containers-operator/aws-region-override/`

**Purpose**: Modifies the install-config.yaml to use a different AWS region than the leased resource, specifically for sandboxed containers operator testing.

**Environment Variables**:
- `AWS_REGION_OVERRIDE`: Explicit region override (highest priority)
- `AWS_ALLOWED_REGIONS`: Space-separated list of allowed regions for validation/selection

## Usage Patterns

### Pattern 1: Force Specific Region for Sandboxed Containers Testing

```yaml
tests:
- as: e2e-sandboxed-containers-eu-west-1
  steps:
    cluster_profile: aws
    pre:
    - chain: ipi-aws-pre
    - ref: sandboxed-containers-operator-aws-region-override
    test:
    - ref: sandboxed-containers-operator-e2e-aws
    post:
    - chain: ipi-aws-post
    env:
      AWS_REGION_OVERRIDE: "eu-west-1"
```

### Pattern 2: Restrict to Regions with Good Sandboxed Containers Support

```yaml
tests:
- as: e2e-sandboxed-containers-allowed-regions
  steps:
    cluster_profile: aws
    pre:
    - chain: ipi-aws-pre
    - ref: sandboxed-containers-operator-aws-region-override
    test:
    - ref: sandboxed-containers-operator-e2e-aws
    post:
    - chain: ipi-aws-post
    env:
      AWS_ALLOWED_REGIONS: "us-east-1 us-west-2 eu-west-1 ap-southeast-1"
```

### Pattern 3: Force Region with Validation

```yaml
tests:
- as: e2e-sandboxed-containers-ap-southeast
  steps:
    cluster_profile: aws
    pre:
    - chain: ipi-aws-pre
    - ref: sandboxed-containers-operator-aws-region-override
    test:
    - ref: sandboxed-containers-operator-e2e-aws
    post:
    - chain: ipi-aws-post
    env:
      AWS_REGION_OVERRIDE: "ap-southeast-1"
      AWS_ALLOWED_REGIONS: "ap-southeast-1 ap-northeast-1 ap-south-1"
```

### Pattern 4: Integration with PeerPods Testing

```yaml
tests:
- as: e2e-sandboxed-containers-peerpods-eu
  steps:
    cluster_profile: aws
    pre:
    - chain: ipi-aws-pre
    - ref: sandboxed-containers-operator-aws-region-override
    - ref: sandboxed-containers-operator-peerpods-param-cm
    test:
    - ref: sandboxed-containers-operator-e2e-aws
    post:
    - chain: ipi-aws-post
    env:
      AWS_REGION_OVERRIDE: "eu-central-1"
```

## Complete CI Configuration Examples

### Example 1: Sandboxed Containers Operator Configuration

```yaml
# Example CI configuration for sandboxed-containers-operator
# Location: ci-operator/config/openshift/sandboxed-containers-operator/

base_images:
  base:
    name: "4.16"
    namespace: ocp
    tag: base

build_root:
  image_stream_tag:
    name: release
    namespace: openshift
    tag: golang-1.21

tests:

# Force installation in a specific region for sandboxed containers testing
- as: e2e-sandboxed-containers-eu-west-1
  steps:
    cluster_profile: aws
    pre:
    - chain: ipi-aws-pre
    - ref: sandboxed-containers-operator-aws-region-override
    test:
    - ref: sandboxed-containers-operator-e2e-aws
    post:
    - chain: ipi-aws-post
    env:
      AWS_REGION_OVERRIDE: "eu-west-1"
  skip_if_only_changed: "^docs/|\\.md$|^(?:.*/)?(?:\\.gitignore|OWNERS|PROJECT|LICENSE)$"

# Test sandboxed containers in US West region
- as: e2e-sandboxed-containers-us-west-2
  steps:
    cluster_profile: aws
    pre:
    - chain: ipi-aws-pre
    - ref: sandboxed-containers-operator-aws-region-override
    test:
    - ref: sandboxed-containers-operator-e2e-aws
    post:
    - chain: ipi-aws-post
    env:
      AWS_REGION_OVERRIDE: "us-west-2"

# Restrict to regions known to work well with sandboxed containers
- as: e2e-sandboxed-containers-allowed-regions
  steps:
    cluster_profile: aws
    pre:
    - chain: ipi-aws-pre
    - ref: sandboxed-containers-operator-aws-region-override
    test:
    - ref: sandboxed-containers-operator-e2e-aws
    post:
    - chain: ipi-aws-post
    env:
      AWS_ALLOWED_REGIONS: "us-east-1 us-west-2 eu-west-1 ap-southeast-1"

# Multi-region testing for sandboxed containers
- as: e2e-sandboxed-containers-us-east-1
  steps:
    cluster_profile: aws
    pre:
    - chain: ipi-aws-pre
    - ref: sandboxed-containers-operator-aws-region-override
    test:
    - ref: sandboxed-containers-operator-e2e-aws
    post:
    - chain: ipi-aws-post
    env:
      AWS_REGION_OVERRIDE: "us-east-1"

- as: e2e-sandboxed-containers-eu-west-1
  steps:
    cluster_profile: aws
    pre:
    - chain: ipi-aws-pre
    - ref: sandboxed-containers-operator-aws-region-override
    test:
    - ref: sandboxed-containers-operator-e2e-aws
    post:
    - chain: ipi-aws-post
    env:
      AWS_REGION_OVERRIDE: "eu-west-1"

# Using with environment config map in specific region
- as: e2e-sandboxed-containers-with-env-cm
  steps:
    cluster_profile: aws
    pre:
    - chain: ipi-aws-pre
    - ref: sandboxed-containers-operator-aws-region-override
    - ref: sandboxed-containers-operator-env-cm
    test:
    - ref: sandboxed-containers-operator-e2e-aws
    post:
    - chain: ipi-aws-post
    env:
      AWS_REGION_OVERRIDE: "ca-central-1"
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
- Target region should support required EC2 instance types for sandboxed containers

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

## Sandboxed Containers Specific Considerations

### Instance Type Availability
- Ensures testing happens in regions where required EC2 instance types are available
- Some regions may have better support for confidential computing features
- Metal instances required for certain sandboxed containers features may not be available in all regions

### Regional Feature Support
- Different AWS regions may have varying support for:
  - AWS Nitro Enclaves
  - Confidential computing instance types
  - Hardware security modules
  - Specialized instance families needed for sandboxed workloads

### Performance Considerations
- Network latency to container registries
- Proximity to development teams
- Cost optimization based on regional pricing

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

## Contributing

When modifying this step:

1. Test with multiple region scenarios
2. Ensure backward compatibility (no override = use leased region)
3. Validate error handling for invalid regions
4. Test with different sandboxed containers configurations
5. Verify instance type availability in target regions
6. Update documentation for any new features
7. Test with different cluster profiles and base domains

## Related Steps

- `sandboxed-containers-operator-peerpods-param-cm`: For PeerPods configuration
- `sandboxed-containers-operator-env-cm`: For environment configuration
- `sandboxed-containers-operator-e2e-aws`: For running the actual tests
