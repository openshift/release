# Google Cloud Dedicated (GCD) CI Configuration

This directory contains step-registry components for running OpenShift
installer e2e tests on Google Cloud Dedicated.

## Prerequisites

1. A GCD project with a Workload Identity Federation (WIF) pool configured
   to trust the CI build cluster's AWS account via STS role chaining.
2. A GCD service account with installer-required IAM roles (compute, DNS,
   storage, IAM, etc.).
3. The WIF pool must have a provider with an attribute condition that
   matches the CI pod's AWS identity.
4. The DPTP team must add the `home_role_arn` to the build cluster's
   `aws-sts-cluster-config` secret so that STS is activated for the
   `gcd` cluster profile.

## Authentication Flow

GCD CI jobs use AWS STS role chaining to authenticate:

```
CI pod (build cluster)
  -> AWS STS token (projected SA token)
  -> home role (build cluster AWS account)
  -> hub role (shared hub AWS account, trusted by GCD WIF)
  -> GCD STS exchanges AWS credentials for GCD access token
  -> impersonates GCD service account
```

ci-operator automatically injects the AWS config file and STS token when
the cluster profile secret contains `home_role_arn`, `hub_role_arn`, and
`target_role_arn`.

The job must set `AWS_PROFILE=hub` because GCD WIF trusts only the hub
account. The `default` profile points to a different target account.

## Cluster Profile Secret (`cluster-secrets-gcd`)

The secret is stored in the CI vault at
`selfservice.vault.ci.openshift.org` and must contain:

| Key | Description |
|-----|-------------|
| `gce.json` | WIF credential config (see format below) |
| `openshift_gcp_project` | GCD project ID with prefix, e.g. `eu0:openshift` |
| `public_hosted_zone` | Base domain for DNS records |
| `ssh-publickey` | SSH public key for node access |
| `ssh-privatekey` | SSH private key for node access |
| `home_role_arn` | ARN of the home IAM role on the build cluster account |
| `hub_role_arn` | ARN of the hub IAM role (trusted by GCD WIF) |
| `target_role_arn` | ARN of the target IAM role |

The vault secret must also have these metadata keys for sync:
```
secretsync/target-namespace: ci
secretsync/target-name: cluster-secrets-gcd
```

## WIF Credential Config Format (`gce.json`)

The credential config is an `external_account` type JSON that tells the
Google SDK how to exchange AWS credentials for GCD tokens:

```json
{
  "universe_domain": "apis-berlin-build0.goog",
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID/providers/PROVIDER_ID",
  "subject_token_type": "urn:ietf:params:aws:token-type:aws4_request",
  "token_url": "https://sts.apis-berlin-build0.goog/v1/token",
  "credential_source": {
    "environment_id": "aws1",
    "region_url": "http://169.254.169.254/latest/meta-data/placement/availability-zone",
    "url": "http://169.254.169.254/latest/meta-data/iam/security-credentials",
    "regional_cred_verification_url": "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"
  },
  "service_account_impersonation_url": "https://iamcredentials.apis-berlin-build0.goog/v1/projects/-/serviceAccounts/SA_EMAIL:generateAccessToken"
}
```

Replace `PROJECT_NUMBER`, `POOL_ID`, `PROVIDER_ID`, and `SA_EMAIL` with
actual values from your GCD WIF setup.

### Generating the credential config

```bash
export GOOGLE_CLOUD_UNIVERSE_DOMAIN=apis-berlin-build0.goog

gcloud iam workload-identity-pools create-cred-config \
  "projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID/providers/PROVIDER_ID" \
  --service-account=SA_EMAIL \
  --aws \
  --output-file=gce.json
```

After generating, verify that the `token_url` and
`service_account_impersonation_url` use `apis-berlin-build0.goog`
endpoints (not `googleapis.com`). The `gcloud` command may default to
public GCP endpoints, and the GCD endpoints must be set manually if so.

## Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `AWS_PROFILE` | `hub` | Select the hub AWS profile trusted by GCD WIF |
| `GOOGLE_CLOUD_UNIVERSE_DOMAIN` | `apis-berlin-build0.goog` | Route API calls to GCD endpoints |
| `FEATURE_SET` | `TechPreviewNoUpgrade` | GCD support is currently TechPreview |
| `PUBLISH` | `Internal` | GCD only supports private DNS zones |
| `DEFAULT_MACHINE_OSIMAGE` | `rhcos10` | RHCOS image published to GCD |

## Troubleshooting

### "STS will not be activated"

```
STS hub and target role ARNs are set for profile gcd but home_role_arn
was not found in Secret aws-sts-cluster-config
```

The DPTP team needs to add the GCD profile's home role ARN to the build
cluster's `aws-sts-cluster-config` secret. Contact them with the ARN
values from the cluster profile secret.

### "Connection refused" to 169.254.169.254

```
HTTPConnectionPool(host='169.254.169.254', port=80): Max retries exceeded
```

The Google SDK is trying to get AWS credentials from the EC2 metadata
service, which means STS was not activated (see above). Once STS is
active, ci-operator injects AWS credentials as environment variables and
the SDK uses those instead of IMDS.

### "external_account" type validation failure

The `ipi-conf-gcd-wif-auth` step validates that `gce.json` contains a
valid `external_account` credential config. If this fails, check:
- The file was uploaded to vault correctly (valid JSON)
- The `type` field is `external_account`
- The vault secret has synced (can take up to 30 minutes)

### gcloud auth succeeds but API calls fail

If `gcloud auth login --cred-file` reports success but subsequent commands
fail, check:
- `GOOGLE_CLOUD_UNIVERSE_DOMAIN` is set to `apis-berlin-build0.goog`
- The `token_url` in `gce.json` uses `sts.apis-berlin-build0.goog`
- The GCD service account has the required IAM roles
