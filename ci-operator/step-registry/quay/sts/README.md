# Quay Operator STS on the shared QE cluster (draft)

These reusable steps prepare an S3 bucket and IAM role in the Quay DEV AWS
account, then invoke the operator repository's Chainsaw STS test on the existing
QA-created Quay QE OpenShift cluster. They support
[quay-operator#1324](https://github.com/quay/quay-operator/pull/1324).

**This draft does not register a runnable job.** Nayan/Brady's job and suite
integration, credential registration, helper image, and a reviewed isolated OLM
installation/teardown adapter are still needed. It does not assume that their new
suite already calls Chainsaw. No live AWS or QE-cluster test has been run for this
change.

## Why new steps

The older QE AWS provisioning uses an IAM user and `sts:AssumeRole`. This test
needs Quay's projected service-account token and `sts:AssumeRoleWithWebIdentity`.
The DEV AWS account holds the bucket and IAM role; it is distinct from the
OpenShift cluster where Quay runs. The cluster must already run on AWS with CCO
Manual mode and a reachable HTTPS OIDC issuer. These steps do not reconfigure CCO.

Each invocation creates a unique labelled namespace, bucket and role. The role
trusts only `system:serviceaccount:<run-namespace>:sts-cco-quay-app` with audience
`openshift`, and permits access only to that run's bucket. This avoids collisions
between tests on a shared cluster. Existing namespaces are never adopted.

The OIDC provider is reused or registered once in the DEV account. Existing
providers must already allow the `openshift` audience; their configuration is not
modified. **The provider is retained even if this run created it**, because another
run can start using it immediately. Its removal is a separate administrator-owned
operation after all users stop. Review this lifecycle choice before enablement.

## Caller contract and execution order

1. Mount the approved QE cluster and DEV AWS credentials described below. Set the
   same `QUAY_STS_REGION` for provisioning and cleanup.
2. Run `quay-sts-provision`. It validates the cluster's `kube-system` UID and the
   AWS caller account, creates the namespace and AWS resources, and writes
   `STS_TEST_NAMESPACE`, `STS_S3_BUCKET`, `STS_S3_REGION`, `STS_ROLE_ARN` and
   `quay-sts-state.json` to `SHARED_DIR`. These contain identifiers, not credentials.
3. The QE job's **pending OLM adapter** installs the PR-built Quay Operator in that
   namespace, watching only that namespace, with `ROLEARN` set to `STS_ROLE_ARN`.
   The adapter must verify cluster-wide CRD compatibility and exclude competing
   operators, including unmanaged deployments. Namespace-scoped installation
   alone does not isolate cluster-wide CRDs. Do not patch the shared operator or
   overwrite shared CRDs. If this cannot be guaranteed, use an agreed dedicated
   test environment instead of enabling this job.
4. Run `quay-sts-test` from the operator PR source checkout. It checks namespace
   ownership, the operator's role/watch scope and overlapping OLM Quay operators,
   then runs `make test-e2e-sts`. The existing test creates a fresh QuayRegistry,
   checks CCO/token configuration, and exercises image push/pull and mirroring.
   Successful transfer alone is not proof of the credential path; review the
   source test's STS assertions when connecting the job. Credential refresh across
   token expiration is not established by this adapter.
5. In the job's post/failure path, clean up the test QuayRegistry and its workloads
   **while the test operator is still running** so finalizers can complete. Then
   uninstall only the test operator through the approved OLM adapter. This must
   also run if provisioning, installation or tests fail partway through.
6. Run `quay-sts-cleanup` last. It verifies identities and ownership, refuses to
   proceed while workloads or operator resources remain, then deletes the owned
   namespace, role and bucket contents/bucket. It retains the cluster and OIDC
   provider. It must run in `post`, not only after successful tests.

No installation adapter is included because the shared QE job and supported OLM
isolation procedure have not been supplied. No IPI cluster creation/destruction,
regular `ocp-latest` job modification, or generated Prow job is included for the
same reason. Review these steps first, then wire them into the confirmed job.

## Proposed credentials (not yet registered)

| Collection/group | Mount | Files | Steps |
| --- | --- | --- | --- |
| `quay-qe/cluster` | `/var/run/quay-qe-cluster` | `kubeconfig`, `cluster_uid` (expected kube-system namespace UID) | All three |
| `quay-dev/aws` | `/var/run/quay-dev-aws` | `account_id`, `access_key`, `secret_key`, optional `session_token` | Provision and cleanup only |

These names are proposed references, not confirmation that collections exist.
Brandon/CI administrators must supply the DEV identity and approve the QE access
reference. Credential values must be registered separately, never committed.
Explicit AWS session credentials and an account check prevent accidental use of
the build worker's role. The functional test step has no DEV provisioning
credential mount. Quay itself receives its identity through the operator/CCO.

The QE identity needs read access to cluster identity, infrastructure, authentication,
CCO configuration, API discovery and CSVs, plus creation/inspection/deletion of
run namespaces and access needed by the existing Chainsaw suite. The caller's
OLM adapter may require additional privileges; do not grant them speculatively.

The DEV provisioning identity needs these operations, constrained by the account's
IAM policy and, where supported, run-resource name/tag conditions:

- STS `GetCallerIdentity`.
- IAM `GetOpenIDConnectProvider`, `CreateOpenIDConnectProvider`,
  `TagOpenIDConnectProvider` for the QE issuer registration.
- IAM `CreateRole`, `TagRole`, `GetRole`, `PutRolePolicy`, `DeleteRolePolicy`,
  `DeleteRole` for `quay-sts-*` roles. Set `QUAY_STS_PERMISSIONS_BOUNDARY` if the
  account requires a boundary. No IAM users or access keys are created.
- S3 `CreateBucket`, `ListBucket`, `GetBucketTagging`, `PutBucketTagging`,
  `PutBucketPublicAccessBlock`, `PutEncryptionConfiguration`, `ListBucketVersions`,
  `ListBucketMultipartUploads`, `AbortMultipartUpload`, `DeleteObject`,
  `DeleteObjectVersion`, `DeleteBucket` for run buckets and their contents.

The workload role has only bucket listing/location/multipart listing and object
get/put/delete/multipart operations. DEV provisioning credentials are not copied
into Quay's configuration.

## Images and tools

The calling ci-operator configuration must supply `quay-sts-tools`: Python 3.11+
with `boto3==1.35.99`; `cli: latest` supplies `oc`. For example, its image build can
use `registry.access.redhat.com/ubi9/python-311` and
`pip install --no-cache-dir boto3==1.35.99`. Agree image ownership/update policy
when wiring the job.

`src-oc` must contain the operator PR checkout, Python 3 with PyYAML for the source
test, Go, make, curl and base64. The test step installs pinned crane v0.20.3 and
gojq v0.12.17 and exposes gojq as jq. The operator Makefile supplies Chainsaw.
The runner needs network access to download tools, the cluster API, registry
routes, and AWS endpoints. Set `QUAY_STS_OPERATOR_DEPLOYMENT` if the approved
installation uses a different deployment name.

## Failure handling and validation

State is saved after each creation for partial cleanup. Namespace UID/label,
role tag and bucket account/tag checks prevent deletion of adopted resources.
S3 versioned objects, delete markers and incomplete multipart uploads are removed.
Deletion errors fail the step and leave state for investigation/retry. A hard
process interruption between resource creation and state persistence, or failure
to tag a bucket, can leave a resource requiring administrator cleanup; identifiers
are recorded in state and run tags. Do not weaken ownership checks to hide leaks.

Offline checks: `python3 hack/test-quay-sts.py`, shell syntax, embedded Python
compilation, registry metadata generation, and ci-operator config validation.
Mocked tests do not establish real IAM permissions, OIDC reachability, CCO behavior,
OLM compatibility or image transfer; those need an enabled live job.

Before enablement, confirm the QE job/suite, credential names and account, IAM
boundary, shared-cluster isolation/teardown, tools image, and retained-provider
lifecycle with the team.
