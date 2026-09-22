# Quay Operator STS on an ephemeral AWS cluster

These steps run the Quay Operator STS/CCO Chainsaw test from
[quay-operator#1324](https://github.com/quay/quay-operator/pull/1324) on an
AWS IPI cluster created for one CI job. The job reuses the established
`ipi-aws-pre-manual-oidc-sts` and `ipi-aws-post-manual-oidc-sts` chains instead
of modifying the shared Quay QE cluster.

## Job lifecycle

The `e2e-sts` job in the Quay Operator `master__ocp-latest` configuration runs:

1. `ipi-aws-pre-manual-oidc-sts` creates an AWS cluster in CCO Manual mode,
   including a per-cluster OIDC provider and platform roles. The chain records
   the provider ARN in `${SHARED_DIR}/aws_oidc_provider_arn`.
2. `quay-sts-provision` validates the cluster, OIDC provider and AWS caller,
   then creates a unique test namespace, S3 bucket, and workload role in the
   leased cluster account. The role trusts only
   `system:serviceaccount:<run-namespace>:sts-cco-quay-app` with audience
   `openshift` and grants access only to the run-owned bucket.
3. `quay-sts-install` installs the PR-built Quay Operator bundle in
   `openshift-operators` with AllNamespaces mode, adds the workload role as the
   operator's `ROLEARN`, and waits for the updated deployment.
4. `quay-sts-test` verifies state and operator configuration, then invokes
   `make test-e2e-sts` from the operator PR source. The Chainsaw test validates
   the CredentialRequest and projected-token configuration and exercises Quay
   image push, pull, and repository mirroring.
5. `quay-sts-teardown` deletes only `quayregistry/sts-cco` and the run-owned
   namespace while the operator is available to process finalizers.
6. `ipi-aws-post-manual-oidc-sts` destroys the cluster and removes the OIDC and
   platform IAM infrastructure created by `ccoctl`.
7. `quay-sts-cleanup` verifies AWS account and resource ownership tags, then
   deletes the run-owned role, bucket contents, and bucket.

All cleanup actions run in the job's post phase. The existing Quay `e2e` and
`e2e-upgrade` jobs are unchanged.

## Credentials and isolation

The job uses the standard `openshift-org-aws` cluster profile. The IPI STS
chain and Quay provisioning steps share `${CLUSTER_PROFILE_DIR}/.awscred`; no
additional Quay QE or Quay DEV credential collection is required. The scripts
set `AWS_EC2_METADATA_DISABLED=true` and validate that the AWS caller owns the
OIDC provider emitted by the IPI chain.

Provisioning state and non-secret identifiers are stored in
`${SHARED_DIR}/quay-sts-state.json` and these files:

- `STS_TEST_NAMESPACE`
- `STS_S3_BUCKET`
- `STS_S3_REGION`
- `STS_ROLE_ARN`

The scripts do not print account IDs, role/provider ARNs, issuer URLs,
kubeconfigs, or credential values.

## Images and tools

`quay-sts-tools` is built by the Quay Operator ci-operator configuration from
UBI Python 3.11 with `boto3==1.35.99`; `cli: latest` supplies `oc` where needed.
The test step runs from `src-oc`, which contains the PR source, Go, make, curl,
base64, and `oc`. It installs pinned crane v0.20.3 and gojq v0.12.17 for the
source Chainsaw test. The operator Makefile supplies Chainsaw.

The job requires network access to the cluster API, AWS endpoints, registry
routes, and the pinned Go module sources.

## AWS permissions

The standard cluster-profile identity already has the permissions needed by
the IPI and ccoctl lifecycle. The Quay-specific provision and cleanup steps use:

- STS `GetCallerIdentity`.
- IAM `GetOpenIDConnectProvider`, `CreateRole`, `TagRole`, `GetRole`,
  `PutRolePolicy`, `DeleteRolePolicy`, and `DeleteRole` for `quay-sts-*` roles.
- S3 `CreateBucket`, `ListBucket`, `GetBucketTagging`, `PutBucketTagging`,
  `PutBucketPublicAccessBlock`, `PutEncryptionConfiguration`,
  `ListBucketVersions`, `ListBucketMultipartUploads`, `AbortMultipartUpload`,
  `DeleteObject`, `DeleteObjectVersion`, and `DeleteBucket` for run buckets.

Set `QUAY_STS_PERMISSIONS_BOUNDARY` if the account requires a boundary for the
workload role. The boundary must be a policy in the same AWS account.

## Validation and failure handling

State is persisted after each resource creation. Namespace UID/label, AWS
account, role tag, and bucket owner/tag checks prevent adopted-resource
cleanup. S3 versions, delete markers, and incomplete multipart uploads are
removed. Cleanup failures retain state so administrators can investigate and
retry without weakening ownership checks.

Offline validation:

```console
python3 hack/test-quay-sts.py
```

The offline suite executes the embedded Python with mocked cluster/AWS APIs and
checks account/issuer rejection, namespace collisions, ownership protection,
partial provisioning, operator configuration, versioned S3 cleanup, sanitized
output, and ephemeral job registration. A successful live `e2e-sts` Prow run is
still required before merge to prove IAM permissions, OLM/CCO reconciliation,
image transfer, and complete post cleanup.
