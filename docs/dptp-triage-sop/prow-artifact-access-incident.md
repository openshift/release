# Prow artifact buckets

Job results are split across two buckets:

| Bucket | Contents | Who can read it |
| --- | --- | --- |
| `test-platform-results-public` | Everything written after the September 2026 cutover | Anyone |
| `test-platform-results` | Everything written before it | Anyone who can log in to `app.ci` |

The old bucket was world-readable and some jobs had written credentials into
their logs. Rotating every exposed secret and scrubbing a petabyte of objects
was not practical, so the bucket was closed instead and a fresh public one was
started alongside it. Nothing was copied: the old bucket keeps its own
180-day lifecycle and empties itself.

Deck presents the two as one timeline. Job history and PR history read both
buckets so that a job's runs do not appear to stop at the cutover, but Deck
refuses to serve the *contents* of anything in `test-platform-results`. An
archived run renders a banner instead of lenses, and its Artifacts link points
at `gcsweb-test-platform-results`, which sits behind OpenShift OAuth.

## How the restriction is enforced

Deck's credentials can read both buckets, so "do not serve the archive" cannot
be a property of the UI: `/view` and `/spyglass/lens/` take a caller-supplied
source, and a hand-written request would otherwise stream any object straight
back out. The rule lives in the storage layer instead. Deck wraps the single
`Opener` that every code path shares and refuses reads from the history bucket
except for the handful of keys history rendering needs — `started.json`,
`finished.json`, `prowjob.json`, `latest-build.txt`, and the
`directory/<job>/<id>.txt` symlink files. Blocked reads surface as "not found",
so callers that already handle a missing artifact degrade rather than error.

Object *names* are deliberately not hidden. Listing is what job history is
built on, so anyone who can reach a history page can enumerate the keys under
an archived run. Only the bytes are withheld.

This is configured by three Deck flags, not by the shared Prow config:

```
--history-bucket=test-platform-results
--history-bucket-browser-prefix=https://gcsweb-test-platform-results-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/
--history-bucket-banner=<optional override>
```

**Do not add `test-platform-results` to `deck.additional_allowed_buckets`.**
Deck already allows it internally for history. Listing it there would make it
an ordinary bucket again and Spyglass would serve its artifacts to anonymous
users, which is the exact thing this setup prevents.

The by-bucket browser prefix in `core-services/prow/02_config/_config.yaml`

```yaml
gcs_browser_prefixes_by_bucket:
  test-platform-results: https://gcsweb-test-platform-results-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/
```

is what sends archived Artifacts links to the OAuth-protected browser. Deck
matches a by-bucket entry ahead of the by-repo `'*'` fallback, so this wins for
archived runs of every repository.

## Constraints to preserve

* Public access prevention stays enabled on `test-platform-results`. Its
  `allUsers` bindings were left in place for a fast rollback and are inert only
  because of PAP; removing PAP republishes the bucket.
* `gcs.ci.openshift.org` and the `gcsweb` deployments on `core-ci` and `app.ci`
  staging read anonymously and must serve only `test-platform-results-public`.
* `gcsweb-test-platform-results` authenticates against `app.ci` but applies no
  SubjectAccessReview, so every Red Hat account can read the archive. That is
  weaker than need-to-know; tighten it with `-openshift-sar` if the exposed
  credentials warrant it.
* Deck reads both buckets with the `test-platform-results-viewer` secret, whose
  service account must hold `roles/storage.objectViewer` on each. Public
  readability of the new bucket does not cover this: a client configured with a
  credentials file never falls back to anonymous access.
* The `origin-ci-test` bucket alias refers to the archive. Leave it mapped to
  `test-platform-results`; the new bucket has no content under those paths.

## Restricting a bucket during a future incident

The steps below are what was done in September 2026 and are reusable. They
prevent anonymous reads from a results bucket while keeping Deck and raw
artifacts available to users authenticated to `app.ci`. Deploy the repository
configuration *before* enabling public access prevention.

### Prepare a bucket-scoped GCS reader

Do not reuse `openshift-private-viewer` for broadly authenticated endpoints: it
can also read `origin-ci-private`. A storage administrator must create a
service account in the project that owns the results bucket and grant it access
only on that bucket.

```console
$ INCIDENT_PROJECT_ID=<bucket-project-id>
$ INCIDENT_READER_NAME=prow-incident-results-viewer
$ INCIDENT_READER="${INCIDENT_READER_NAME}@${INCIDENT_PROJECT_ID}.iam.gserviceaccount.com"
$ gcloud iam service-accounts create "${INCIDENT_READER_NAME}" \
    --project="${INCIDENT_PROJECT_ID}" \
    --display-name="Temporary Prow incident results viewer"
$ gcloud storage buckets add-iam-policy-binding gs://<bucket> \
    --member="serviceAccount:${INCIDENT_READER}" \
    --role=roles/storage.objectViewer
```

Store the service-account key in GSM (collection `test-platform-infra`, group
`prow-tpr-viewer`, field `credentials.json`). After `ci-secret-bootstrap` syncs
the bundle, `app.ci` has `secret/test-platform-results-viewer` with key
`credentials.json`. GSM secret id:

`test-platform-infra__prow-tpr-viewer__credentials--dot--json`

### Gate Deck

Put an `oauth-proxy` sidecar in front of Deck, move the `deck` Service and its
Routes to the proxy's port, and point `gcs_browser_prefixes` and
`gcs_browser_prefixes_by_bucket` at an OAuth-protected GCSWeb. Commits
`12ef6bc1065` and `9cf5436919e` are the worked example. Move the Deck and
GCSWeb health monitors in `core-services/ship-status/component-monitor-config.yaml`
and `clusters/app.ci/openshift-user-workload-monitoring/blackbox_probe.yaml` to
`/oauth/healthz` for as long as the gate is up, or they will page.

Verify that an anonymous request to `https://prow.ci.openshift.org/` receives
the OAuth login page, then as a normal authenticated user check a job, its
Build Log, and a raw artifact.

The gated proxies require a successful `app.ci` OAuth login but apply no
additional SubjectAccessReview. Authentication does not grant the user
Kubernetes or GCS permissions; the bucket-scoped backend credential performs
the reads.

### Contain public access

Preserve the existing public bindings for a quick rollback and override them
with public access prevention:

```console
$ gcloud storage buckets update gs://<bucket> --public-access-prevention
```

Enforcement can take up to ten minutes. Anonymous requests should then return
`401` or `403`:

```console
$ curl -I https://storage.googleapis.com/<bucket>/
```

Immediately repeat the authenticated job, Build Log, and raw-artifact checks,
and verify that a newly started job can still upload. Disable public access
prevention immediately if authenticated reads or new uploads fail.

Uploads continue through the separate `gce-sa-credentials-gcs-publisher`
credential, and existing ProwJob and GitHub status URLs stay valid because the
Deck hostname does not change.

The ToT fallback and consumers such as TestGrid or Sippy that read artifacts
anonymously will be degraded while public access prevention is active. Do not
reset the `tot-storage` PVC during containment. Search-indexed results,
internet caches, and signed URLs are not revoked by public access prevention
and must be handled separately if they are in scope.

If credentials were exposed in job output, rotate or revoke them independently.
Restricting a bucket cannot invalidate copies that were already downloaded or
cached.
