# ROSA Marketplace Release Monitor: Usage and Typical Cases

## Current operating mode

The monitor runs every four hours for the configured OpenShift y-stream. It
detects a built nightly payload and validates its RHCOS metadata. Marketplace
publishing is currently disabled, so a successful run observes and records data
without invoking a generator.

Do not enable publishing merely by changing `MARKETPLACE_PUBLISH_ENABLED`. The
current job has neither an approved Marketplace generator image nor mounted
Marketplace AWS credentials. See the enablement checklist below.

## Normal scheduled usage

The source configuration is:

```text
ci-operator/config/openshift/release/
  openshift-release-main__rosa-marketplace-release.yaml
```

Its important settings are:

```yaml
tests:
- as: rosa-marketplace-release-detect
  interval: 4h
  steps:
    env:
      MARKETPLACE_PUBLISH_ENABLED: "false"
      TARGET_OCP_Y_STREAM: "5.2"
    test:
    - ref: rosa-marketplace-release-detect
    - ref: rosa-marketplace-release-publish
```

The steps share `SHARED_DIR`, so the publisher reads the detector's state and
validated values automatically.

## Changing the monitored release

To move the monitor from 5.2 to 5.3:

1. Change `TARGET_OCP_Y_STREAM` in the source CI configuration.
2. Update the corresponding assertion in
   `hack/rosa-marketplace-release-monitor-tests.sh`.
3. Regenerate the Prow jobs.
4. Run the full fixture suite and configuration validators.
5. Rehearse the periodic on the pull request.

Example source change:

```yaml
TARGET_OCP_Y_STREAM: "5.3"
```

No detector branch, version-specific parser, or new fixture set is required when
the upstream contracts remain unchanged.

## Inspecting the upstream API manually

Set the stream explicitly:

```bash
BASE_URL="https://amd64.ocp.releases.ci.openshift.org/api/v1"
Y_STREAM="5.1"
STREAM="${Y_STREAM}.0-0.nightly"
```

Confirm the stream configuration:

```bash
curl --fail --silent --show-error \
  --proto '=https' --proto-redir '=https' \
  "${BASE_URL}/releasestream/${STREAM}/config" |
  jq '{name, hide, endOfLife, to}'
```

Inspect the ready-stream signal used by the detector:

```bash
curl --fail --silent --show-error \
  --proto '=https' --proto-redir '=https' \
  "${BASE_URL}/releasestreams/ready" |
  jq --arg stream "${STREAM}" '{($stream): .[$stream]}'
```

Resolve a selected ready tag to its pullspec:

```bash
curl --fail --silent --show-error \
  --proto '=https' --proto-redir '=https' \
  "${BASE_URL}/releasestream/${STREAM}/tags" |
  jq --arg tag "<selected-ready-tag>" \
    '{name, tags: [.tags[] | select(.name == $tag) | {name, phase, pullSpec}]}'
```

These commands are diagnostic only. The values change as upstream payloads are
created and processed.

## Running local validation

Run the deterministic suite:

```bash
bash hack/rosa-marketplace-release-monitor-tests.sh
```

The suite covers:

| Area | Coverage |
|---|---|
| `release-controller-api` | Settings, HTTPS, response validation, HTTP behavior, retries and size limits |
| `payload-selection` | Empty and malformed ready responses, deterministic ready-tag selection, exact tag resolution, and phase-transition races |
| `rhcos-extraction` | Installer extraction, RHCOS release and regional AMI handling |
| `prow-contract` | Step references, source CI configuration and generated Prow wiring |
| `publisher` | State handoff, safety gates, generator arguments and exit propagation |

The fixture tests do not require a cluster, network access, AWS credentials, or
a real release payload. They use fake curl, sleep, installer, and generator
commands.

## Regenerating and validating repository configuration

After changing source CI or step-registry configuration, run the applicable
repository generators and validators:

```bash
make registry-metadata
make jobs
make ci-operator-checkconfig
make validate-step-registry
make checkconfig
git diff --check
```

Container-backed targets require a working local container runtime. If they
cannot run locally, report that limitation and rely on the repository presubmit
and Prow rehearsal for the equivalent validation.

Generated files under `ci-operator/jobs/openshift/release/` must match their
source configuration. Do not place detailed behavior directly in generated job
files.

## Rehearsing the CI jobs

Run the deterministic presubmit and live periodic from the pull request:

```text
/pj-rehearse pull-ci-openshift-release-main-rosa-marketplace-release-monitor-test periodic-ci-openshift-release-main-rosa-marketplace-release-rosa-marketplace-release-detect
```

Run only the live periodic when debugging detector integration:

```text
/pj-rehearse periodic-ci-openshift-release-main-rosa-marketplace-release-rosa-marketplace-release-detect
```

A successful live rehearsal should show the detector and publisher steps both
succeeding. With publishing disabled, publisher success means a safe no-op, not
a Marketplace release.

## Reading detector results

Start with:

```text
${SHARED_DIR}/rosa-marketplace-release-state
```

Interpret it as follows:

| Value | Operator interpretation | Action |
|---|---|---|
| `ready` | A built payload and required RHCOS metadata were found | Inspect output values and publisher result |
| `wait:stream-config-unavailable` | The configured future stream does not exist | No action unless the stream should already exist |
| `wait:stream-tags-unavailable` | The stream exists but tags are not available | Wait; investigate if persistent |
| `wait:built-nightly-unavailable` | The ready response contains no tag for the target stream | Normal lifecycle wait |

For `ready`, inspect:

```text
rosa-marketplace-ocp-version
rosa-marketplace-payload-tag
rosa-marketplace-payload-pullspec
rosa-marketplace-rhcos-version
rosa-marketplace-rhcos-ami
```

Downloaded config, ready-streams, and tags responses and the CoreOS stream
document are retained in `ARTIFACT_DIR` for troubleshooting.

## Typical cases

### Case 1: Monitoring a future release before its nightly stream exists

Configuration:

```yaml
TARGET_OCP_Y_STREAM: "5.2"
MARKETPLACE_PUBLISH_ENABLED: "false"
```

Expected result:

```text
wait:stream-config-unavailable
```

The job succeeds and the publisher skips. This is an expected lifecycle state.

### Case 2: Stream exists but no payload has been built

The config request succeeds, but the target stream is absent from the ready
response or its ready-tag list is empty.

Expected result:

```text
wait:built-nightly-unavailable
```

The next four-hour run checks again.

### Case 3: More than one built payload is present

If the target stream has multiple tags in the ready response, the detector
sorts their names and selects the earliest one. It then resolves only that tag
in the stream tags response. This provides a stable choice independent of
response order.

Expected outputs include `ready`, the selected tag and pullspec, and the RHCOS
version and regional AMI extracted from that payload.

### Case 4: A ready payload changes phase during resolution

The ready endpoint and tags endpoint are separate requests. A selected payload
may move from `Ready` to `Accepted` or `Rejected` between them. The detector
accepts either transition because the ready response already established that
the payload image was built. It does not claim that a rejected payload is an
accepted OpenShift release or independently authorize Marketplace publication.

### Case 5: Upstream returns malformed or mismatched data

Examples include invalid JSON, a response naming another stream, a selected
payload without a pullspec, or invalid RHCOS fields.

Expected result: the detector fails. These are contract or integrity errors, not
normal lifecycle waits.

### Case 6: Transient release-controller failure

HTTP 429, HTTP 5xx, or curl failure is retried with exponential backoff up to
the configured attempt count and delay ceiling. The detector continues when a
later attempt succeeds and fails when all attempts are exhausted.

### Case 7: Detector is ready but publishing remains disabled

Expected publisher log:

```text
No action: publishing is disabled for ocp_version=<major.minor>
```

The publisher exits successfully without looking for or invoking the generator.
This is the expected production behavior of the initial monitor.

### Case 8: Production Marketplace is configured

Expected result: the publisher fails with `only the staging Marketplace
environment is allowed`. Production is intentionally unsupported.

### Case 9: Enabled staging dry-run after prerequisites are supplied

Only after the enablement checklist is complete, set:

```yaml
MARKETPLACE_PUBLISH_ENABLED: "true"
MARKETPLACE_DRY_RUN: "true"
MARKETPLACE_ENVIRONMENT: staging
```

The publisher validates detector values and invokes:

```text
marketplace-release-generator release
  --environment staging
  --ocp-version <major.minor>
  --rhcos-version <rhcos-release>
  --aws-profile <profile>
  --copy-if-duplicate=false
  --timeout <duration>
  --dry-run
```

Any generator failure propagates as a failed step.

## Publishing enablement checklist

Before setting `MARKETPLACE_PUBLISH_ENABLED=true` in a real CI job:

- Replace the publisher's generic CLI runtime with an approved immutable digest
  or protected image-stream tag containing the generator.
- Mount the reviewed staging AWS credentials.
- Verify the AWS profile name and least-privilege permissions.
- Keep `MARKETPLACE_ENVIRONMENT=staging`.
- Run and review a dry-run rehearsal.
- Agree on duplicate handling, rollback, alerting, and operational ownership.
- Obtain required ROSA, Technical Release Team, and DPTP reviews for the files
  changed by the enablement work.

## Fixture maintenance

Fixtures are maintained per consumed contract, not per OpenShift release.

Do not refresh them simply because the target changes from 5.2 to 5.3. Update or
add fixtures only when:

- The fields consumed from release-controller or installer output change.
- The eligible payload policy changes.
- A defect needs a deterministic regression case.

Keep fixtures minimal. Do not replace them with responses downloaded from a
moving upstream branch during presubmit execution. The existing four-hour
periodic is responsible for detecting live upstream integration drift.

## Troubleshooting guide

| Symptom | Check first |
|---|---|
| `stream-config-unavailable` persists | Confirm the exact `<major>.<minor>.0-0.nightly` stream exists |
| `stream-tags-unavailable` persists | Query the stream's `/tags` endpoint and inspect HTTP status |
| `built-nightly-unavailable` persists | Inspect the target stream's array in `/api/v1/releasestreams/ready` |
| Payload extraction fails | Verify pull-secret mount, pullspec access, and `oc` availability |
| RHCOS version or AMI missing | Run the selected payload's installer with `coreos print-stream-json` |
| Publisher reports missing output | Confirm the detector reached `ready` and both steps share `SHARED_DIR` |
| Generator not found | Publishing was enabled without the approved generator image |
| Prow cannot pull `stable:cli-artifacts` | Do not add `cli: latest` unless the job configures the corresponding release input |

When reporting a failure, include the detector state, relevant step log, selected
payload tag, and uploaded artifacts. Never include registry authentication or
AWS credential contents.
