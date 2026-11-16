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

## Authorization and renewal checks

`test_manifest.py` renders separately named Jobs and a new ConfigMap, preserving
prior runs. It requires a dedicated test bucket containing the following harmless
objects, uploaded without overwriting any existing generation:

- `smoke/allowed.txt`: `build13 direct WIF allowed test object` followed by a newline.
- `smoke/denied.txt`: a separate harmless test file.

The test GCP service account gets `roles/storage.objectViewer` on this bucket with
an IAM condition matching only the exact allowed object's `resource.name`.
It receives no project-wide storage role. The bucket uses uniform access and
public access prevention.

Create a separate external-account config using the original provider/account
and `--service-account-token-lifetime-seconds=600`. Then render the test resources:

```sh
python3 hack/gcp-wif-smoke/test_manifest.py \
  /path/to/external-account-600.json \
  abc123 \
  openshift-ci-build13-wif-smoke-20261116-70628c > /tmp/build13-wif-tests.json
oc --context="$BUILD13_CONTEXT" create --dry-run=server -f /tmp/build13-wif-tests.json
oc --context="$BUILD13_CONTEXT" create -f /tmp/build13-wif-tests.json
```

Choose a fresh six-character hexadecimal run suffix instead of `abc123` for each
run. All Jobs are additive and have no automatic expiry.

The Jobs run these checks:

- **Denied identity:** a new Kubernetes ServiceAccount with no IAM grant must
  receive an explicit IAM 403 denying `iam.serviceAccounts.getAccessToken`.
  Network errors and unrelated failures do not count as a pass.
- **Resource access:** the allowed file must return its exact expected contents.
  Reading the other file and listing the bucket must receive explicit storage
  permission denials. GCS media errors can be HTML; metadata/list errors are JSON.
- **Renewal:** the Google auth library reads the allowed file every 30 seconds for
  15 minutes with 10-minute GCP credentials and a 10-minute projected Kubernetes
  token. It must automatically refresh target credentials after initial issuance,
  continue beyond the first credential expiry, and observe projected-token
  rotation. A separate fresh client must then exchange the rotated pod token and
  read the object. Only counters are logged, never token values or fingerprints.

The pinned Google CLI image supplies its own Python and Google auth library;
the test discovers those paths with `gcloud info`. It does not install packages
or use personal ADC, AWS credentials, or a service-account private key.

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

## Follow-up run, 2026-11-16

- `gcp-wif-denied-70628c` completed successfully: the unbound Kubernetes identity
  received IAM 403 for `iam.serviceAccounts.getAccessToken`.
- `gcp-wif-resource-70628d` completed successfully: the exact allowed object was
  read, while the other object and bucket listing were explicitly denied.
- `gcp-wif-renewal-70628c` completed successfully after 900 seconds and 31
  successful reads. It observed three GCP access-token generations, two projected
  Kubernetes-token generations, and three automatic IAM refreshes. A separate
  fresh client completed another STS exchange using the rotated pod token.

All three Jobs completed with `1/1` success. Detailed non-secret evidence is
recorded in [results-20261116.json](results-20261116.json). Resource access is scoped
to the test object; DNS access, other clusters, and consumer migrations remain
outside this test's scope.

The dedicated private bucket is
`gs://openshift-ci-build13-wif-smoke-20261116-70628c`. Only the exact allowed object
is included in the test account's conditional, bucket-scoped viewer grant.
The earlier resource run `gcp-wif-resource-70628c` is retained: it failed in the
test's JSON parsing of an expected HTML permission denial, not because access
was granted. The separately named retry accepts explicit permission denials in
either response format.

## Retention

Retain both test runs and the isolated test resources until cleanup is explicitly
requested. The existing `build13` pool/provider belongs to the cluster and must
not be removed as part of test cleanup.

## Read-only rollout inventory, 2026-11-16

[Recorded observations](inventory-20261116.json) distinguish source configuration
from live, publicly observable state. No rollout configuration has been applied.

Build02, build04, and build08 each return OIDC discovery with issuer
`https://kubernetes.default.svc`. Their conventional `buildNN-oidc` bucket URLs
return 404, and no same-named cluster pools were found in the two checked projects,
`openshift-ci-build-farm` and `openshift-ci-infra`. This does not rule out pools in
other projects or mirrors at other URLs. Public signing-key retrieval could not
be verified from this session; authenticated contexts for those clusters are not
available.

The next isolated pilot should be build02, after cluster-owner review of the trust
setup. Google's Kubernetes guide supports supplying a cluster's public JWKS to an
OIDC provider, which can avoid changing a control-plane issuer for a smoke test.
Verified JWKS retrieval and a signing-key rotation plan are prerequisites. A
stable public issuer is another approach, but no cluster-wide issuer change is
included here. Use a separate pool per cluster, or an equally strong
cluster-qualified principal binding, and grant only the exact pilot identity.
Repeat the successful build13 checks before progressing to build04 and build08.

Cert-manager is a later consumer canary. The checked-in ClusterIssuers still
reference `key.json` for `openshift-ci-infra` and
`openshift-ci-build-farm-cert-issuer.json` for the build-farm project. The build13
account cannot read the deployed cert-manager controller, so its installed
version and supported Operator configuration for projected-token/external-account
ADC must be confirmed by maintainers first. The upstream GKE annotation examples
are not a recipe for these OpenShift clusters. Start with a separate canary
issuer and test DNS scope; keep existing issuers, certificates and key Secrets
until a separately reviewed migration succeeds. No deletion is part of this plan.

Reference: https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes
