# Restricting Prow artifacts during an incident

This procedure prevents anonymous reads from `gs://test-platform-results` while
keeping normal Deck and raw-artifact access available to users authenticated to
the `app.ci` cluster. It does not broaden access to `origin-ci-private`.

The repository configuration must be deployed before public access prevention
is enabled. It makes these temporary changes:

* The normal Deck endpoint requires OpenShift OAuth authorization and retains
  its existing tenant filters and URLs.
* Deck reads GCS with a temporary credential that can read only
  `test-platform-results`.
* A dedicated OAuth-protected GCSWeb serves only `test-platform-results`.
* The existing `gcsweb-private` service and `openshift-private-viewer`
  credential remain restricted to private-CI users.

## Prepare a bucket-scoped GCS reader

Do not use `openshift-private-viewer` for the broadly authenticated endpoints:
it can also read `origin-ci-private`. A storage administrator must create a
temporary service account in the project that owns the results bucket and grant
it access only on `test-platform-results`.

```console
$ INCIDENT_PROJECT_ID=<bucket-project-id>
$ INCIDENT_READER_NAME=prow-incident-results-viewer
$ INCIDENT_READER="${INCIDENT_READER_NAME}@${INCIDENT_PROJECT_ID}.iam.gserviceaccount.com"
$ gcloud iam service-accounts create "${INCIDENT_READER_NAME}" \
    --project="${INCIDENT_PROJECT_ID}" \
    --display-name="Temporary Prow incident results viewer"
$ gcloud storage buckets add-iam-policy-binding gs://test-platform-results \
    --member="serviceAccount:${INCIDENT_READER}" \
    --role=roles/storage.objectViewer
```

Create the Kubernetes secret without printing the key and remove the local key
file immediately afterward:

```console
$ INCIDENT_KEY_DIR="$(mktemp -d)"
$ gcloud iam service-accounts keys create "${INCIDENT_KEY_DIR}/credentials.json" \
    --iam-account="${INCIDENT_READER}" \
    --project="${INCIDENT_PROJECT_ID}"
$ oc --context app.ci -n ci create secret generic test-platform-results-viewer \
    --from-file=credentials.json="${INCIDENT_KEY_DIR}/credentials.json" \
    --dry-run=client -o yaml | oc --context app.ci -n ci apply -f -
$ shred -u "${INCIDENT_KEY_DIR}/credentials.json"
$ rmdir "${INCIDENT_KEY_DIR}"
```

Deploy the repository configuration. Verify that an anonymous request to
`https://prow.ci.openshift.org/` receives the OAuth login page. Then, as a
normal authenticated user, verify an existing job, its Build Log, and a raw
artifact at:

```text
https://gcsweb-test-platform-results-ci.apps.ci.l2s4.p1.openshiftapps.com/
```

The incident-facing proxies require successful `app.ci` OpenShift OAuth login
but do not apply an additional SubjectAccessReview. Authentication does not
grant the user Kubernetes or GCS permissions; the bucket-scoped backend
credential performs artifact reads.

## Contain public access

Preserve the existing public bindings for a quick rollback and override them
with public access prevention:

```console
$ gcloud storage buckets update gs://test-platform-results --public-access-prevention
```

Enforcement can take up to ten minutes. Anonymous requests to the bucket should
then return `401` or `403`:

```console
$ curl -I https://storage.googleapis.com/test-platform-results/
```

Immediately repeat the authenticated job, Build Log, and raw-artifact checks.
Also verify that a newly started job can upload artifacts. Disable public access
prevention immediately if authenticated reads or new uploads fail.

Prow uploads continue through the separate
`gce-sa-credentials-gcs-publisher` credential. Existing ProwJob and GitHub
status URLs remain valid because the normal Deck hostname does not change.

The ToT fallback and consumers such as TestGrid or Sippy that read artifacts
anonymously can be degraded while public access prevention is active. Do not
reset the `tot-storage` PVC during containment. Search-indexed results, internet
caches, and signed URLs are not revoked by public access prevention and must be
handled separately if they are in scope for the incident.

## Restore public access

First disable public access prevention:

```console
$ gcloud storage buckets update gs://test-platform-results --no-public-access-prevention
```

Verify public Deck, GCSWeb, TestGrid, Sippy, and ToT fallback behavior. Revert
the incident configuration, then remove the temporary bucket grant:

```console
$ gcloud storage buckets remove-iam-policy-binding gs://test-platform-results \
    --member="serviceAccount:${INCIDENT_READER}" \
    --role=roles/storage.objectViewer
```

Delete the `test-platform-results-viewer` Kubernetes secret and revoke the
temporary service-account key according to the incident credential-handling
process. If `openshift-private-viewer` was temporarily granted access during
the initial response, remove that bucket grant after the bucket-scoped reader
has been verified.

If credentials were exposed in job output, rotate or revoke them independently;
restricting the bucket cannot invalidate copies that were already downloaded or
cached.
