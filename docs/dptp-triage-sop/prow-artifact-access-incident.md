# Restricting Prow artifacts during an incident

This procedure prevents anonymous reads from `gs://test-platform-results` while
keeping Deck and raw artifact access available to users authorized for the
`ocp-priv` image stream.

The repository configuration must be deployed before public access prevention
is enabled. It makes these temporary changes:

* The normal Deck endpoint requires OpenShift OAuth authorization while
  retaining its existing tenant filters and URLs.
* Deck reads GCS with the `openshift-private-viewer` credential.
* The OAuth-protected private GCSWeb serves `test-platform-results` in addition
  to `origin-ci-private`.

## Prepare the GCS reader

Get the service account used by the existing reader-only credential:

```console
$ READER_SERVICE_ACCOUNT="$(oc --context app.ci -n ci get secret openshift-private-viewer -o jsonpath='{.data.credentials\.json}' | base64 --decode | jq -r .client_email)"
```

Grant that service account read-only access to the public results bucket:

```console
$ gcloud storage buckets add-iam-policy-binding gs://test-platform-results \
    --member="serviceAccount:${READER_SERVICE_ACCOUNT}" \
    --role=roles/storage.objectViewer
```

Do not grant the Deck Kubernetes service account, publisher credential, or
anonymous principals read access. Deck must use the reader-only credential and
must not be externally reachable around its OAuth proxy.

After the configuration has rolled out, verify that an anonymous request to
`https://prow.ci.openshift.org/` is redirected to login. Then verify an existing
normal job and its raw artifacts as an authorized user.

## Contain public access

Preserve the existing public bindings for a quick rollback and override them
with public access prevention:

```console
$ gcloud storage buckets update gs://test-platform-results --public-access-prevention
```

Anonymous requests should now return `401` or `403`. Prow uploads continue via
the separate `gce-sa-credentials-gcs-publisher` credential.

Existing ProwJob and GitHub status URLs remain valid because the normal Deck
hostname does not change.

Generated raw-artifact links use the private GCSWeb hostname. Hard-coded
`gcs.ci.openshift.org` links remain unavailable; replace that hostname with
`gcsweb-private-ci.apps.ci.l2s4.p1.openshiftapps.com` when authorized access is
required.

The ToT fallback and consumers such as TestGrid or Sippy that read artifacts
anonymously can be degraded while public access prevention is active. The ToT
fallback is only consulted when its persistent store has no build number for a
job. Do not reset the `tot-storage` PVC during containment. The public GCSWeb
ship-status monitor will also report the intentionally blocked bucket; silence
that alert for the containment window.

## Restore public access

First disable public access prevention:

```console
$ gcloud storage buckets update gs://test-platform-results --no-public-access-prevention
```

Verify public Deck, GCSWeb, TestGrid, Sippy, and ToT fallback behavior. Then
revert the incident configuration and remove the temporary reader grant:

```console
$ gcloud storage buckets remove-iam-policy-binding gs://test-platform-results \
    --member="serviceAccount:${READER_SERVICE_ACCOUNT}" \
    --role=roles/storage.objectViewer
```

If credentials were exposed in job output, rotate or revoke them independently;
restricting the bucket cannot invalidate copies that were already downloaded or
cached.
