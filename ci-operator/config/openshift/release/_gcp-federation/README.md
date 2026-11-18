# AWS hub to GCP standard-client compatibility check

The optional `gcp-hub-profile-check-jobs2-gcloud` job targets build07 and the
existing `gcp-openshift-gce-devel-ci-2` cluster profile. It first checks the
profile's service-account email and project metadata, without using the private
key. It creates an isolated child Job in its own CI namespace. That Job mounts
no shared profile or static cloud credentials.

The child Job uses build07's projected service-account token to assume the
existing AWS home role and then `ci-step-runner-hub`. A native sidecar exposes
refreshable hub credentials on `127.0.0.1:8085` in the AWS metadata format.
The pinned Google CLI image uses an `external_account` credential file pointed
at that loopback endpoint and the existing `aws-ci-hub` GCP provider. Only the
sidecar receives the projected pod token. No Service exposes its endpoint.

This sidecar is a test harness for validating standard Google clients. It is
not a change to shared ci-operator authentication or a proposed production
deployment. Google tools do not directly consume boto3's chained AWS profile.
The test uses the existing provisioner service account in CI Jobs 2 through its
authorized Workload Identity User binding. Its only project API calls list a
Compute Engine zone. It creates or deletes no cloud resources.

Checks:

- `gcloud auth login --cred-file` and token acquisition.
- Read-only Compute Engine zone listing through gcloud.
- The same read through Google's standard application-default credential loader.

Tokens and AWS credentials stay within the test pod. Command output containing
tokens is captured and discarded, and logs contain only fixed check results.
The Google CLI token cache is under a memory-backed `/tmp` volume. The sidecar
is terminated automatically when the test client exits. Kubernetes test objects
remain available for inspection until normal CI namespace cleanup.

Run before merge by commenting on PR #88397:

```
/pj-rehearse pull-ci-openshift-release-main-gcp-hub-profile-check-jobs2-gcloud
```

The optional `jobs2-identity` job only verifies the profile mapping. The
`aws-gcp-federation-offline-unit` job runs the offline harness checks. This PR
does not create a new cluster profile or Boskos resource, and does not use the
superseded AWS broker role.

The two Jobs 2 checks have explicit test-name exceptions to the profile-set
policy so they can pin the existing Jobs 2 profile. Randomly choosing another
GCP project would not test the service-account binding being validated here.

Offline checks:

```
python3 -m unittest discover -s ci-operator/config/openshift/release/_gcp-federation -p 'test_*.py'
```

Live standalone validation on November 18, 2026 passed gcloud authentication,
gcloud zone listing, and the standard Google library zone listing from build07.
The test does not establish OpenShift installer or cleanup compatibility, or
long-running credential renewal through the standard-client sidecar. Existing
profiles and static keys are unchanged; switching shared jobs remains separate.
