# AWS hub to GCP standard-client check

The optional build07 job selects the existing `openshift-org-aws` profile set.
Boskos assigns an AWS quota slice and ci-operator mounts the AWS configuration
and projected service account token in the test step. The helper selects the
`hub` profile and checks its caller identity before serving temporary credentials
on the pod's loopback interface.

The Google external-account configuration selects the `aws-ci-hub` provider
and the Jobs 2 provisioner service account. The job checks impersonation and
reads a Compute Engine zone through both gcloud and the Google auth library.
It uses the profile's role chain and does not read the profile's static keys.

To rehearse the job on PR #88397, comment:

```
/pj-rehearse pull-ci-openshift-release-main-gcp-hub-profile-check-jobs2-gcloud
```

The `aws-gcp-federation-offline-unit` job checks the Google client's handling
of refreshed AWS credentials with a local test server.
