# HyperShift Standalone AWS Pre-setup Chain

This chain provides an alternative to `ipi-aws-pre` for workflows that need to use:
- Custom AWS credentials (instead of cluster profile leasing)
- Fixed AWS region and zones (instead of dynamic resource allocation)

## Usage

Replace your existing `ipi-aws-pre` chain with `hypershift-standalone-aws-pre`:

```yaml
workflow:
  as: my-custom-workflow
  steps:
    pre:
    - chain: hypershift-standalone-aws-pre
    test:
    - ref: my-test-step
    post:
    - chain: ipi-aws-post
```

## Configuration

Set the following environment variables in your workflow:

```yaml
env:
- name: FIXED_AWS_REGION
  value: "us-west-2"  # Your desired AWS region
- name: FIXED_AWS_ZONES
  value: "us-west-2a,us-west-2b,us-west-2c"  # Comma-separated zones
- name: STANDALONE_AWS_CREDS_FILE
  value: "/path/to/your/aws/credentials"  # Optional: custom AWS creds
- name: ZONES_COUNT
  value: "3"  # Will be automatically set based on FIXED_AWS_ZONES count
```

## Key Differences from `ipi-aws-pre`

| Feature | `ipi-aws-pre` | `hypershift-standalone-aws-pre` |
|---------|---------------|----------------------------------|
| Region Selection | Dynamic via Boskos leasing | Fixed via `FIXED_AWS_REGION` |
| Zone Selection | Dynamic discovery + instance type filtering | Fixed via `FIXED_AWS_ZONES` |
| AWS Credentials | Cluster profile credentials | Custom credentials supported |
| IAM User Creation | Creates minimal permission IAM user | Skipped (assumes existing creds) |
| Zone Count | Limited by region instance type availability | Guaranteed based on fixed zones |

## Components Included

- ✅ **ipi-conf**: Generic cluster configuration
- ✅ **ipi-conf-telemetry**: Telemetry settings
- 🔧 **ipi-conf-aws-standalone**: Custom AWS config with fixed region/zones
- ✅ **ipi-conf-aws-byo-ipv4-pool-public**: IPv4 pool configuration
- ✅ **ipi-install-monitoringpvc**: Monitoring PVC setup
- ✅ **ipi-install**: Complete installation chain
- 🚫 **aws-provision-iam-user-minimal-permission**: Skipped

## Troubleshooting

1. **Invalid zones**: Ensure `FIXED_AWS_ZONES` contains valid zones for your `FIXED_AWS_REGION`
2. **Instance type availability**: The script still validates instance type availability in your fixed zones
3. **Credentials**: If `STANDALONE_AWS_CREDS_FILE` is not provided, it falls back to cluster profile credentials

## Example Complete Workflow

```yaml
workflow:
  as: hypershift-standalone-test
  steps:
    cluster_profile: aws-2  # Still needed for base domain and other configs
    env:
    - name: FIXED_AWS_REGION
      value: "us-east-1"
    - name: FIXED_AWS_ZONES
      value: "us-east-1a,us-east-1b,us-east-1c"
    - name: CONTROL_PLANE_INSTANCE_TYPE
      value: "m6i.xlarge"
    - name: COMPUTE_NODE_TYPE
      value: "m6i.xlarge"
    pre:
    - chain: hypershift-standalone-aws-pre
    test:
    - ref: hypershift-aws-run-reqserving-e2e
    post:
    - chain: ipi-aws-post
```
