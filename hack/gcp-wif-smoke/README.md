# Build13 direct OIDC to Google Cloud smoke test

Tests pod ServiceAccount JWT → Google STS → Google service-account impersonation.
Uses build13's public issuer, no AWS roles, no cluster profile, no Boskos lease,
and no service-account private key. The test GCP service account receives no
project resource roles; this first test proves authentication only.

The setup is isolated to project `openshift-ci-build-farm`, pool and GCP service
account `build13-wif-smoke`, and Kubernetes namespace `wif-smoke` with ServiceAccount
`gcp-smoke`. The provider accepts only that exact issuer and Kubernetes subject.
The generated external-account file is configuration, not a private key.

## Run

Requires a current `gcloud auth login`, permission to manage the test identity
pool/service account, and an authenticated build13 context with permission to
create the test namespace, ServiceAccount, ConfigMap and Job. Setup verifies the
context's issuer before creating cloud resources. It creates the narrow
`roles/iam.workloadIdentityUser` binding on the test GCP service account only.

```sh
export BUILD13_CONTEXT="your-build13-context"
bash hack/gcp-wif-smoke/setup.sh
oc --context="$BUILD13_CONTEXT" create namespace wif-smoke --dry-run=client -o yaml | oc --context="$BUILD13_CONTEXT" apply -f -
oc --context="$BUILD13_CONTEXT" apply --dry-run=server -f /tmp/build13-wif-smoke/smoke.json
oc --context="$BUILD13_CONTEXT" apply -f /tmp/build13-wif-smoke/smoke.json
oc --context="$BUILD13_CONTEXT" -n wif-smoke wait --for=condition=complete job/gcp-wif-smoke --timeout=300s
oc --context="$BUILD13_CONTEXT" -n wif-smoke logs job/gcp-wif-smoke
```

Use a dedicated test namespace; the commands create it before server dry-run of
the namespaced objects. Expect `PASS: build13 pod identity obtained short-lived
GCP credentials.` No JWTs or access tokens are printed. A failure must be
investigated rather than treated as a successful negative test. For a retry,
delete only the completed/failed Job before applying the manifest again.

After this passes, test an unauthorized Kubernetes ServiceAccount and confirm an
explicit trust/authorization rejection. Then test token renewal and a narrowly
authorized harmless resource read. Enabling issuers on build02/04/08 and migrating
cert-manager are separate follow-ups; this test changes no existing consumers.

## Cleanup

Delete only the test Job, ConfigMap and Kubernetes ServiceAccount in `wif-smoke`.
Remove the test principal's IAM binding, then delete the dedicated GCP service
account and dedicated identity pool when no longer needed. Do not reuse this pool
for production identities or add other cluster providers to it; this initial test
binds an exact subject within this single-provider pool.

Reference: https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes
