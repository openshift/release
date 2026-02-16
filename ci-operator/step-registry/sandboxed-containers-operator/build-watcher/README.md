# sandboxed-containers-operator-build-watcher

## Purpose

This step automatically watches for new accepted OpenShift Container Platform (OCP) releases and triggers OpenShift Sandboxed Containers (OSC) testing jobs to ensure continuous validation against the latest OCP builds.

This replaces the previous Jenkins-based build watcher that monitored https://amd64.ocp.releases.ci.openshift.org/ and triggered jobs based on Google Spreadsheet state.

## How It Works

The build watcher:

1. **Queries Cincinnati API** for latest accepted releases across multiple OCP versions (4.17-4.22)
2. **Checks Prow Deck API** to see if the version was already tested in the last 24 hours
3. **Triggers jobs via Gangway API** for untested versions
4. **Reports results** in the job logs

## OCP Versions Monitored

- 4.17.0-0.nightly
- 4.18.0-0.nightly
- 4.19.0-0.nightly
- 4.20.0-0.nightly
- 4.21.0-0.nightly
- 4.22.0-0.nightly

## Jobs Triggered

For each new OCP version, the following downstream-release jobs are triggered:

- `periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-release-azure-ipi-kata`
- `periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-release-azure-ipi-peerpods`
- `periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-release-azure-ipi-coco`
- `periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-release-aws-ipi-peerpods`
- `periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-release-aws-ipi-coco`

## Requirements

### Gangway API Token

This step requires a Gangway API token to trigger jobs. The token must be:

1. **Requested from DPTP team** - Open a ticket with the Test Platform team requesting Gangway API access
2. **Stored in Vault** with the following configuration:
   - **Namespace**: `test-credentials`
   - **Secret name**: `osc-build-watcher-secrets`
   - **Key**: `gangway-api-token`
   - **Value**: The token provided by DPTP

### Vault Configuration

To add the secret to Vault:

1. Sign into https://vault.ci.openshift.org
2. Navigate to your secret collection (e.g., `kv/sandboxed-containers-operator`)
3. Create a new secret named `osc-build-watcher-secrets`
4. Add keys:
   - `secretsync/target-namespace` → `test-credentials`
   - `gangway-api-token` → `<your-token-from-DPTP>`

## Configuration

The watcher is configured to run daily at 00:00 UTC as a periodic job. See the periodic job configuration in:
`ci-operator/config/openshift/sandboxed-containers-operator/openshift-sandboxed-containers-operator-devel__build-watcher.yaml`

## Deduplication Logic

The watcher prevents duplicate testing by:

1. Querying Prow Deck API (`/prowjobs.js`) for recent job runs
2. Checking if the specific job succeeded in the last 24 hours
3. Skipping jobs that were recently tested successfully

**Note**: The current implementation checks for recent successful runs of the job, not the exact OCP version. This is a reasonable heuristic since the jobs run against nightly builds that change frequently.

## Behavior

- **Rehearsal Mode**: Automatically skips execution when `JOB_NAME` contains "rehearse"
- **Error Handling**:
  - Reports failures but continues processing other versions
  - Exits with error code if any job triggers fail
- **Logging**: Provides detailed output of all operations and decisions

## Example Output

```
=========================================
OpenShift Sandboxed Containers Build Watcher
=========================================
Date: Mon Jan 20 00:00:00 UTC 2026

✓ Gangway API token loaded

Checking OCP versions for new releases...

----------------------------------------
Processing OCP 4.21
----------------------------------------
Querying Cincinnati API for 4.21.0-0.nightly...
  ✓ Latest accepted release: 4.21.0-0.nightly-2026-01-19-132300

Job: periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-release-azure-ipi-kata
  Checking if job was tested with 4.21.0-0.nightly-2026-01-19-132300 in last 24 hours...
    ✗ No recent successful run found
  Triggering job: periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-release-azure-ipi-kata
    ✓ Successfully triggered (HTTP 201)
    → Triggered for OCP 4.21.0-0.nightly-2026-01-19-132300

=========================================
Summary
=========================================
Jobs triggered: 5
Jobs skipped:   30
Jobs failed:    0

✓ Build watcher completed successfully
```

## Troubleshooting

### Token Not Found Error

```
ERROR: Gangway API token not found at /var/run/osc-secrets/gangway-api-token
```

**Solution**: Verify the secret is properly configured in Vault with `secretsync/target-namespace` set to `test-credentials`.

### Failed to Query Cincinnati API

```
⚠ Failed to query Cincinnati API for 4.21.0-0.nightly
```

**Solution**: Check network connectivity and verify the Cincinnati API endpoint is accessible.

### Failed to Trigger (HTTP 403)

```
✗ Failed to trigger (HTTP 403)
```

**Solution**: The Gangway API token may be invalid or expired. Request a new token from DPTP.

### Failed to Query Deck API

```
⚠ Failed to query Deck API
```

**Solution**: Temporary network issue. The watcher will retry on the next scheduled run.

## Related Documentation

- [Prow Gangway API](https://docs.prow.k8s.io/)
- [OpenShift Release Controllers](https://amd64.ocp.releases.ci.openshift.org/)
- [OpenShift CI Secrets Guide](https://cspi.gitbook.io/ocp-ci-onboarding/tutorials/secrets_guide)

## JIRA Reference

This implementation addresses [KATA-3819](https://issues.redhat.com/browse/KATA-3819) - Automated triggering of OSC tests for new OCP releases.
