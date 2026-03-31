# OpenShift Mirroring Failures

This SOP covers the `openshift-mirroring-failures` alert on `app.ci`.

## What this alert means

This alert fires when OpenShift image-mirroring jobs have no successful run in the configured time window.
In practice, this means we are seeing a series of failures and need to restore at least one successful run.

## Primary goal

Get one successful run of `periodic-image-mirroring-openshift` after the failure streak.

The exact fix depends on the failure type, but the path to recovery is usually fixing image-related errors (for example `manifest unknown`, missing tags/digests, or invalid manifests), then rerunning or waiting for the next periodic run.

## Triage

1. Open the failing job history:
   - <https://prow.ci.openshift.org/?job=periodic-image-mirroring-openshift>
2. Confirm repeated failures and identify the latest failure log.
3. Extract the first concrete error from `oc image mirror` output.
4. Analyze the failure:
   - Source image problem (`manifest unknown`, missing image/tag, bad digest)
   - Destination push/auth problem (permission denied, auth/credentials)
   - Registry/network/transient problem (timeouts, temporary API failures)
5. Apply the minimal fix needed to get a successful run.

## Common recovery actions

- Fix or rebuild broken source images, usually by rerunning related postsubmit(s).
- If transient, retrigger and verify the next run succeeds.

## Success criteria

- At least one successful `periodic-image-mirroring-openshift` run is observed in Prow.
- The alert resolves after success is recorded.

