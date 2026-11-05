# Isolated AWS-to-GCP federation diagnostic

Tracking: [DPTP-5300](https://redhat.atlassian.net/browse/DPTP-5300).

Status: local CI draft, not merged, deployed or run in CI. Dedicated AWS/GCP
pilot resources exist; the AWS configuration is based on user-provided console
policies. The GCP provider, impersonation binding and marker read grant were
read back separately. This directory is the source used by the proposed jobs;
the earlier standalone script in ci-tools remains a historical local draft.

## What runs

The pilot adds three optional, manually triggered tests on build07 with amd64
step pods. The offline check is in a separate `aws-gcp-federation-offline`
variant so resolving its configuration does not require the new live profile:

- `aws-gcp-federation-offline-unit`: offline checks with fake credentials and no cloud profile.
- `aws-gcp-federation-gcp-wif`: short access and rejection diagnostic.
- `aws-gcp-federation-gcp-wif-renewal`: the same checks, then repeated reads for
  at least 4500 seconds to observe AWS and Google credential renewal.

The two live tests use the dedicated `gcp-aws-federation-pilot` profile and a new one-slot
Boskos resource type. The scheduling resource is an authentication-test slot,
not a region or a lease on an installer account. This avoids selecting a shared
profile through a profile-set lease or consuming installation quota. Neither
test is added to an existing workflow or profile set, and neither runs
automatically as ordinary presubmits on PR updates. PR rehearsals can discover
new/changed jobs. All tests retain the intranet-access restriction; public
AWS/Google endpoints do not require lifting that restriction.

The diagnostic accepts only the two role fields in the mounted profile. It
validates the exact generated home/hub/broker configuration and token-routing
claims, then explicitly constructs the AWS-to-Google credential supplier.
AWS validates the actual projected token signature; local claim inspection is
only a routing check. Personal ADC is not used. The test makes no resource
creation or IAM mutation calls.

The custom credential class uses Google's public `aws.RequestSigner` with the
provider audience passed as an additional signed header. This includes
`x-goog-cloud-target-resource` in SigV4 SignedHeaders, rather than appending it
after signing. Offline checks exercise actual request serialization, credential
cloning and two coherent supplier generations without making network calls.

The existing ci-operator/controller, image-pull, GSM and artifact-upload
credentials remain part of normal CI operation. This test's no-key claim is
about the diagnostic's cloud authentication, not all surrounding CI services.
The generated Prow jobs retain the current generator's ordinary CSI settings;
this does not implement the separate CSI-only profile-secret proposal.

## Required one-time CI metadata setup

Before deploying the new bundle, a maintainer must use the existing CI secret
management process to seed exactly these fields:

- Collection: `test-platform-infra`.
- Group: `gcp-aws-federation-pilot`.
- `hub_role_arn`: `arn:aws:iam::320297955214:role/ci-step-runner-hub`.
- `target_role_arn`: `arn:aws:iam::320297955214:role/ci-step-runner-gcp-broker`.

These values are identifiers, not access keys. Do not add `gce.json`, `.awscred`,
pull secrets or other profile fields. The diagnostic fails if unexpected fields
are present. The new bootstrap bundle targets only build07 and creates
`ci/cluster-secrets-gcp-aws-federation-pilot` with the two fields.

The build07 home ARN remains in the existing `ci/aws-sts-cluster-config` Secret;
its source is the `build07` field of the existing `aws-sts-cluster-config` group.
A maintainer must verify that it resolves to
`arn:aws:iam::891612575819:role/ci-step-runner`. Do not update a shared home
configuration just to run this pilot.

No new broad cluster permission is needed for test authors. Maintainers can
seed the two metadata fields and deploy the normal reviewed CI changes.

## Rollout and first run

The offline test needs no pilot profile or Boskos slot and can be rehearsed
on this PR before deployment:

```text
/pj-rehearse pull-ci-openshift-release-main-aws-gcp-federation-offline-unit
```

For the live tests:

1. Review the dedicated profile, metadata bundle and one-slot Boskos changes.
   Seed the new group before allowing bootstrap to reconcile it.
2. Apply the prerequisites through the established CI deployment process and
   verify the two-field Secret and free scheduling slot on build07. A merged
   source change alone does not prove that these resources are deployed.
3. Review the image, diagnostic and generated job changes. New profiles may not
   resolve in rehearsal until the prerequisites are deployed; do not count an
   unknown-profile or missing-lease failure as an authentication result.
4. On the unmerged PR, use the specific rehearsal command for the short job:

   ```text
   /pj-rehearse pull-ci-openshift-release-main-aws-gcp-federation-gcp-wif
   ```

5. After the short job passes, rehearse renewal:

   ```text
   /pj-rehearse pull-ci-openshift-release-main-aws-gcp-federation-gcp-wif-renewal
   ```

After the jobs are merged and deployed, their ordinary `/test` commands are
`/test aws-gcp-federation-gcp-wif` and
`/test aws-gcp-federation-gcp-wif-renewal`. A new unmerged job must use rehearsal
rather than assuming the ordinary test plugin already knows about it.

Both live jobs serialize through the same slot. Preserve their Prow URLs,
`federation.jsonl` artifacts, source commit and actual pod image IDs.

## Success and rejection evidence

The short job requires all of the following:

- GetCallerIdentity reports the exact expected broker assumed-role identity.
- The broker exchanges credentials through the dedicated AWS provider and
  explicitly impersonates
  `ci-aws-wif-pilot@openshift-ci-build-farm.iam.gserviceaccount.com`.
- `federation-pilot.txt` in the dedicated bucket
  `openshift-ci-build-farm-aws-wif-pilot-20261104-nr` returns HTTP 200 and SHA256
  `8db3eeff8275a7c4d172305c12070eca247dd90fb58a668961a953018abeb695`.
- The known-existing `denied-control.txt` and bucket listing both return 403.
  A 404, token failure or network error does not count as authorization denial.
- A real hub-role identity in the same AWS account as the broker is separately
  signed and presented to Google STS, which must reject it with `invalid_grant` specifically referring
  to the provider attribute condition. An invalid audience, networking failure
  or local config rejection does not count.

Using the hub isolates the role restriction: it matches the provider's AWS
account but differs from the permitted broker role. A home-role request from
build07's different AWS account could be rejected at the account check instead,
so it is not used as evidence of the role condition.

The renewal job additionally requires at least two observed Google token
generations and two distinct supplied AWS credential generations after at least
4500 seconds of repeated reads. It logs only counters, expiry timestamps and
selected identity metadata. It never prints tokens, signed requests, credential
values, object content or raw SDK/OAuth error bodies.

The home role's observed maximum session duration is one hour. This initial
renewal run does not independently prove every intermediate session lifetime
or rotation of the projected Kubernetes token, whose requested lifetime may be
longer. Corroborate identities with AWS/Google audit evidence, then extend the
test if needed. A diagnostic success does not validate an installer.

The pilot service account has an additional pre-existing self-binding of
`roles/iam.serviceAccountAdmin`, retained pending owner review. Storage-denial
checks are still useful, but do not describe this
identity as having only marker-read capabilities. This diagnostic does not
exercise that administrative permission or change any IAM policy.

## Local validation

The Red Hat Python 3.12 base image is pinned by manifest digest, and all Python
runtime dependencies are pinned in `requirements.txt`. The diagnostic emits
the actual auth library versions. A local amd64 image built successfully and
passed eight test methods (37 cases, including two signed-request generations) with networking disabled.
Python 3.14 host checks also passed. The local ARM container hit SIGILL while
importing Google auth; ARM runtime compatibility is not claimed, and CI step
architecture is explicitly amd64.

From the release repository root, using the appropriate validation tools:

```sh
python3 ci-operator/config/openshift/release/_gcp-federation/test_diagnostic.py
ci-operator-checkconfig --config-dir ci-operator/config --registry ci-operator/step-registry \
  --cluster-profiles-config ci-operator/step-registry/cluster-profiles/cluster-profiles-config.yaml \
  --cluster-claim-owners-config core-services/cluster-pools/_config.yaml --org openshift --repo release
git diff --check
```

GSM schema validation also passed using the current ci-tools
`api.LoadGSMConfigFromFile` and `GSMConfig.Validate` functions without querying
secret stores. The full ci-secret-bootstrap CLI still validates existing Vault
item references even in validate-only mode; its live-store checks are left to
the normal repository CI/maintainer environment. No new access to existing
secret payloads is requested for this draft.

Regenerate jobs with ci-operator-prowgen and Boskos configuration with
`generate-boskos.py`; do not hand-edit the generated YAML. Existing jobs and
lease definitions must remain unchanged apart from the new pilot additions.

No live CI run, rejection test or renewal test has been performed yet.
