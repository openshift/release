# ROSA Marketplace Release Monitor: Design

## Purpose

The ROSA Marketplace release monitor connects OpenShift nightly payload
availability to the ROSA Marketplace release workflow. It periodically checks a
configured OpenShift y-stream, identifies the earliest payload whose image was
built, extracts the RHCOS metadata embedded in that payload, and passes validated
values to a separately gated publisher.

The initial deployment is intentionally observation-only: publishing is disabled
by default. This allows the detection path to run against the real release
controller and release payloads before Marketplace credentials or a generator
image are introduced.

## Goals

- Poll one configured OpenShift nightly y-stream every four hours.
- Distinguish a normal lifecycle wait from an operational or data error.
- Select the earliest built payload deterministically.
- Derive RHCOS version and AWS AMI data from the selected payload, rather than
  maintaining a release-specific mapping in this repository.
- Pass detector results to a publisher through an explicit file contract.
- Prevent accidental production publication.
- Provide deterministic fixture tests and a rehearsable live integration job.

## Non-goals

- Deciding OpenShift release policy or payload acceptance policy.
- Publishing to the production Marketplace environment.
- Storing a permanent catalog of payloads, RHCOS versions, or AMIs.
- Maintaining separate detector implementations for every OpenShift release.
- Enabling publishing before an approved generator image and credentials are
  available.

## Architecture

```text
4-hour Prow periodic
        |
        v
rosa-marketplace-release-detect
        |
        |  GET /api/v1/releasestream/<stream>/config
        |  GET /api/v1/releasestream/<stream>/tags
        v
OpenShift release controller
        |
        |  selected payload pullspec
        v
oc adm release extract --command=openshift-install
        |
        v
openshift-install coreos print-stream-json
        |
        |  state, OCP version, payload, RHCOS version, AWS AMI
        v
SHARED_DIR file contract
        |
        v
rosa-marketplace-release-publish
        |
        +-- wait:*  -> successful no-op
        +-- disabled -> successful no-op
        +-- enabled  -> staging-only generator invocation
```

## Component structure

### CI source configuration

`ci-operator/config/openshift/release/openshift-release-main__rosa-marketplace-release.yaml`
defines the four-hour periodic, its input image, target y-stream, and ordered
detector and publisher steps.

`ci-operator/config/openshift/release/openshift-release-main.yaml` defines the
change-triggered fixture presubmit.

Files under `ci-operator/jobs/openshift/release/` are generated Prow
configuration. They mirror the source configuration and must be regenerated,
not edited as the source of truth.

### Detector step

`ci-operator/step-registry/rosa/marketplace/release/detect/` contains the
step-registry reference, metadata, ownership, and detector implementation.

The detector performs five operations:

1. Validate settings and construct `<major>.<minor>.0-0.nightly` from
   `TARGET_OCP_Y_STREAM`.
2. Confirm that the release-controller stream exists and that its response
   identifies the expected stream.
3. Read the stream tags and choose the lexically earliest payload in `Ready`,
   `Accepted`, or `Rejected` phase. Those phases establish that a payload image
   was built; they do not make a Marketplace release decision.
4. Extract `openshift-install` from the selected payload and execute
   `coreos print-stream-json`.
5. Validate and record the x86_64 RHCOS release and the AMI for the configured
   AWS region.

### Publisher step

`ci-operator/step-registry/rosa/marketplace/release/publish/` contains the
step-registry reference, metadata, ownership, and publisher implementation.

The publisher consumes the detector contract. It skips lifecycle wait states,
accepts only the `staging` environment, and invokes the generator only when
`MARKETPLACE_PUBLISH_ENABLED=true`.

The current periodic explicitly sets publishing to `false`. Its CLI image does
not supply the Marketplace generator or Marketplace AWS credentials. Before the
publisher can be enabled, the consuming job must use an approved immutable or
protected generator image and mount the required staging credentials.

### Tests and fixtures

`hack/rosa-marketplace-release-monitor-tests.sh` provides grouped fixture and
configuration-contract tests. `hack/rosa-marketplace-release-monitor/` contains
minimal JSON inputs and fake external commands.

Fixtures model contracts and edge conditions; they are not snapshots of each
OpenShift release. A new y-stream does not require a new fixture set when the
API shape and detector rules are unchanged.

The four-hour periodic supplies the complementary live contract test: it calls
the real release controller and uses the real payload's installer. Keeping the
fixture presubmit and live periodic separate prevents temporary upstream state
or network failures from making deterministic PR validation unreliable.

## Detector input contract

| Variable | Required/default | Meaning |
|---|---|---|
| `TARGET_OCP_Y_STREAM` | Required | Major/minor stream such as `5.2` |
| `RELEASE_CONTROLLER_API` | `https://amd64.ocp.releases.ci.openshift.org` | HTTPS release-controller base URL |
| `RELEASE_CONTROLLER_RETRIES` | `3` | Maximum transient request attempts |
| `RELEASE_CONTROLLER_RETRY_DELAY_SECONDS` | `2` | Initial retry delay |
| `RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS` | `30` | Backoff ceiling |
| `RELEASE_CONTROLLER_MAX_RESPONSE_BYTES` | `10485760` | Maximum accepted response size |
| `RELEASE_PAYLOAD_AUTH_FILE` | `/etc/pull-secret/.dockerconfigjson` | Registry authentication used by `oc` |
| `RHCOS_AWS_REGION` | `us-east-1` | Region whose AMI is required |

The API URL must be HTTPS and cannot contain user information, a query, or a
fragment. Redirects are restricted to HTTPS. Transient HTTP responses are
retried with capped exponential backoff, and response data is rejected before
JSON parsing when it exceeds the configured limit.

## Detector output contract

All outputs are written to `SHARED_DIR` as single-line files.

| File | Written when | Meaning |
|---|---|---|
| `rosa-marketplace-release-state` | Always for normal lifecycle outcomes | `ready` or `wait:<reason>` |
| `rosa-marketplace-ocp-version` | After settings validation | Requested major/minor version |
| `rosa-marketplace-payload-tag` | `ready` | Selected payload tag |
| `rosa-marketplace-payload-pullspec` | `ready` | Selected payload pullspec |
| `rosa-marketplace-rhcos-version` | `ready` | Installer-provided RHCOS release |
| `rosa-marketplace-rhcos-ami` | `ready` | Installer-provided regional AMI |

`ARTIFACT_DIR` also receives the downloaded config and tags documents, the
selected payload object, and the installer-generated CoreOS stream document for
debugging.

## State and failure model

Normal lifecycle conditions are successful no-ops:

| State | Cause |
|---|---|
| `wait:stream-config-unavailable` | The requested nightly stream does not exist yet |
| `wait:stream-tags-unavailable` | The stream exists but its tags endpoint is unavailable |
| `wait:built-nightly-unavailable` | No `Ready`, `Accepted`, or `Rejected` payload exists |
| `ready` | Payload and required RHCOS metadata were validated |

Unexpected HTTP status codes, invalid JSON, mismatched stream names, missing
required fields, failed payload extraction, invalid RHCOS data, and invalid
configuration fail the detector. This distinction keeps an unreleased future
stream quiet while making broken contracts visible.

## Publisher safety model

The publisher evaluates controls in this order:

1. Skip every `wait:*` detector state.
2. Reject states other than `ready` or `wait:*`.
3. Refuse any environment except `staging`.
4. Validate that the enable flag is exactly `true` or `false`.
5. Return successfully before generator discovery when publishing is disabled.
6. When enabled, validate dry-run, profile, timeout, detector values, and the
   generator executable before invocation.

The generator receives validated arguments and `--copy-if-duplicate=false`.
Dry-run defaults to `true`. Production is not an accepted configuration.

## Ownership boundaries

OWNERS files route review and approval; they do not define release rules.

| Area | Effective owner |
|---|---|
| `ci-operator/config/openshift/release/` | Technical Release Team |
| `ci-operator/jobs/openshift/release/` | Technical Release Team |
| `ci-operator/step-registry/rosa/` | ROSA team, with nearer subdirectory OWNERS taking precedence |
| `hack/` | Repository-root DPTP ownership unless a nearer OWNERS file exists |

The feature consequently crosses ROSA, Technical Release Team, and DPTP review
boundaries.

## Release-version maintenance

The version is data, not a code switch. Moving from 5.2 to 5.3 changes
`TARGET_OCP_Y_STREAM` in the CI source configuration and its configuration
assertion. The detector automatically constructs the corresponding nightly
stream and uses the same parser and selection rules.

Fixtures change only when the consumed response contract, the selection policy,
or a regression case changes. They do not change merely because a new release
is created.

## Future enablement requirements

Publishing must remain disabled until all of the following are agreed and
implemented:

- An approved immutable digest or protected image-stream tag containing the
  Marketplace generator.
- A reviewed AWS credential secret and mount owned by the appropriate team.
- Confirmation of the staging AWS profile and generator argument contract.
- A successful staging dry-run rehearsal followed by an explicitly reviewed
  non-dry-run rehearsal.
- Operational ownership, alerting, rollback, and duplicate-publication policy.
