# Build13 direct OIDC to Google Cloud smoke test

Tests pod ServiceAccount JWT → Google STS → Google service-account impersonation.
Uses build13's public issuer, no AWS roles, no cluster profile, no Boskos lease,
and no service-account private key. The test GCP service account receives no
project resource roles; this first test proves authentication only.

The test reuses the existing `build13` pool/provider in project
`openshift-ci-build-farm`, created by OpenShift ccoctl. Its accepted token audience
is `openshift`. It creates GCP service account `build13-wif-smoke` and binds only
Kubernetes subject `system:serviceaccount:gcp-wif-smoke-nirichar:gcp-smoke` to impersonate it.
Existing provider settings and existing consumers are not modified.
The generated external-account file is configuration, not a private key.

## Run

Requires a current `gcloud auth login`, permission to create the test GCP
service account, manage its IAM policy, and read the existing provider. The build13
account needs permission to create a dedicated OpenShift project, or access to the
existing test project, and permission to create its ServiceAccount, ConfigMap and Job. Setup verifies the
context's issuer before creating cloud resources. It creates the narrow
`roles/iam.workloadIdentityUser` binding on the test GCP service account only.

```sh
export BUILD13_CONTEXT="your-build13-context"
oc --context="$BUILD13_CONTEXT" new-project gcp-wif-smoke-nirichar --skip-config-write
bash hack/gcp-wif-smoke/setup.sh
oc --context="$BUILD13_CONTEXT" apply --dry-run=server -f /tmp/build13-wif-smoke/smoke.json
oc --context="$BUILD13_CONTEXT" apply -f /tmp/build13-wif-smoke/smoke.json
oc --context="$BUILD13_CONTEXT" -n gcp-wif-smoke-nirichar wait --for=condition=complete job/gcp-wif-smoke --timeout=300s
oc --context="$BUILD13_CONTEXT" -n gcp-wif-smoke-nirichar logs job/gcp-wif-smoke
```

Create the dedicated project only once; skip `new-project` on subsequent runs.
The manifest contains only namespaced test resources. Expect `PASS: build13 pod identity obtained short-lived
GCP credentials.` No JWTs or access tokens are printed. A failure must be
investigated rather than treated as a successful negative test. For a retry, use a separately named Job so prior results remain available.
Jobs have no automatic expiry; retain them until cleanup is explicitly requested.

After this passes, test an unauthorized Kubernetes ServiceAccount and confirm an
explicit trust/authorization rejection. Then test token renewal and a narrowly
authorized harmless resource read. Enabling issuers on build02/04/08 and migrating
cert-manager are separate follow-ups; this test changes no existing consumers.

## Verified run, 2026-11-16

Job `gcp-wif-smoke-2` in build13 project `gcp-wif-smoke-nirichar` completed
successfully. `gcloud auth login --cred-file` authenticated as the test GCP
service account and `gcloud auth print-access-token` succeeded with its output
discarded. The result was:

```text
PASS: build13 pod identity obtained short-lived GCP credentials.
```

The first Job failed before authentication because `python3` was not on the
image's PATH. The retry removed the redundant local JWT parsing; Google STS
validates the token during exchange. The first Job was preserved, and its automatic
expiry was removed. New Jobs have no automatic expiry.

The test account had no user-managed keys. No project resource roles were granted.
This verifies authentication and impersonation only, not access to storage/DNS,
credential renewal, other build clusters, or migration of existing consumers.

## Retention

Retain both test runs and the isolated test resources until cleanup is explicitly
requested. The existing `build13` pool/provider belongs to the cluster and must
not be removed as part of test cleanup.

Reference: https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes
