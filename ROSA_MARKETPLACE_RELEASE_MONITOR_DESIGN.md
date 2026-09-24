# ROSA Marketplace Release: Payload-Driven Design

## Purpose

The ROSA Marketplace release job connects a newly built OpenShift payload to
the staging Marketplace workflow without maintaining a fixed OCP version in a
standalone polling job. Release-controller supplies the exact payload, the job
derives its y-stream and RHCOS metadata, and the publisher safely decides
whether a staging Marketplace version is needed.

Publishing remains disabled by default. The first deployment validates the
payload-driven integration without invoking the generator or requiring AWS
Marketplace credentials.

## Goals

- Run for release-controller payloads instead of discovering payloads by API polling.
- Derive the OCP y-stream from immutable payload metadata.
- Carry the job into a new OCP release through the standard pre-branch process.
- Extract RHCOS version and regional AMI data from the payload's installer.
- Make repeated payloads and retries safe with an idempotent generator guard.
- Keep the job optional so it cannot reject an OpenShift payload.
- Prevent production publication.

## Non-goals

- Defining OpenShift payload acceptance policy.
- Polling release-controller `/config`, `/ready`, `/latest`, or `/tags` APIs.
- Keeping a repository mapping from OCP versions to RHCOS versions or AMIs.
- Publishing to the production Marketplace environment.
- Enabling publication before an approved generator image and credentials exist.

## Architecture

```text
OCP pre-branch automation
        |
        | carries nightly CI and release-controller job configuration forward
        v
release-controller builds a payload
        |
        | starts optional/informing ProwJob
        | supplies RELEASE_IMAGE_LATEST
        v
rosa-marketplace-release-detect
        |
        | oc adm release info -> payload version -> OCP y-stream
        | oc adm release extract --command=openshift-install
        | openshift-install coreos print-stream-json
        v
SHARED_DIR: payload, OCP y-stream, RHCOS version, regional AMI
        |
        v
rosa-marketplace-release-publish
        |
        +-- disabled -> successful no-op
        +-- enabled  -> staging generator with --skip-if-version-exists
```

## Trigger and release-version lifecycle

The source job is named `rosa-marketplace-release` in
`ci-operator/config/openshift/release/openshift-release-main__nightly-5.1.yaml`.
It is registered as an optional verification job in
`core-services/release-controller/_releases/release-ocp-5.1.json`.

The periodic definition gives Prow a reusable job object and makes manual
`/pj-rehearse` possible. Release-controller is the operational trigger and
injects the payload being evaluated. The annual schedule is not used for
release discovery; if it runs, ci-operator supplies the current nightly
candidate through the same `RELEASE_IMAGE_LATEST` contract.

The normal OCP pre-branch change, such as the automated 5.0-to-5.1 change,
copies versioned nightly configurations and release-controller definitions to
the next y-stream. Consequently, ROSA code has no `TARGET_OCP_Y_STREAM` switch
to edit for each release. Reviewers of the generated pre-branch change must
still confirm that both Marketplace job entries were carried forward. That is
a configuration-generation contract, not a runtime version switch.

The presence of the optional job in a release definition is the policy signal
that the y-stream participates in this ROSA workflow. Removing that entry
disables the integration for a stream without adding policy to the script.

## Components

### CI and release-controller configuration

- The versioned nightly configuration defines the reusable ProwJob and release
  input that provides `RELEASE_IMAGE_LATEST` during manual rehearsal.
- The release-controller definition registers that ProwJob as optional.
- Generated files under `ci-operator/jobs/` mirror the CI source and are not
  edited as the source of truth.
- The fixture presubmit in `openshift-release-main.yaml` validates scripts and
  the cross-file configuration contract.

### Detector

The detector:

1. Requires the `RELEASE_IMAGE_LATEST` payload supplied by ci-operator.
2. Inspects it with `oc adm release info -o json`.
3. Validates the full payload version and derives `<major>.<minor>`.
4. Extracts that payload's `openshift-install`.
5. Runs `coreos print-stream-json` and validates the x86_64 RHCOS release and
   configured regional AMI.
6. Writes a `ready` state and validated values to `SHARED_DIR`.

There are no lifecycle wait states. A release-controller invocation already
has a concrete payload, so missing or malformed payload data is an actionable
failure.

### Publisher

The publisher accepts only detector state `ready` and only the `staging`
environment. It exits successfully before generator discovery when
`MARKETPLACE_PUBLISH_ENABLED=false`.

When explicitly enabled, it invokes the generator with both
`--copy-if-duplicate=false` and `--skip-if-version-exists`. The latter makes
later payloads for the same y-stream and release-controller retries successful
no-ops after a Marketplace version exists.

The current CLI image does not contain the Marketplace generator or mounted
AWS credentials. Publication cannot be enabled until an approved immutable or
protected generator image and reviewed staging credentials are configured.

## Data contract

Input supplied by CI:

| Value | Required/default | Meaning |
|---|---|---|
| `RELEASE_IMAGE_LATEST` | Required, injected by ci-operator | Exact payload pullspec under evaluation |
| `RELEASE_PAYLOAD_AUTH_FILE` | `/etc/pull-secret/.dockerconfigjson` | Registry authentication for payload inspection |
| `RHCOS_AWS_REGION` | `us-east-1` | Region whose installer-provided AMI is required |

Detector outputs are single-line files under `SHARED_DIR`:

| File | Meaning |
|---|---|
| `rosa-marketplace-release-state` | `ready` after complete validation |
| `rosa-marketplace-ocp-version` | Derived OCP y-stream, such as `5.1` |
| `rosa-marketplace-payload-tag` | Full version from payload metadata |
| `rosa-marketplace-payload-pullspec` | Exact `RELEASE_IMAGE_LATEST` value |
| `rosa-marketplace-rhcos-version` | Installer-provided RHCOS release |
| `rosa-marketplace-rhcos-ami` | Installer-provided AMI for the configured region |

`ARTIFACT_DIR` retains the release-info and CoreOS stream JSON documents for
troubleshooting. Credentials are never copied or logged.

## Safety and failure model

- Missing payload, registry authentication, version, RHCOS data, or AMI fails.
- Invalid JSON and invalid version/value formats fail.
- `oc`, installer, and generator failures propagate.
- Production Marketplace configuration fails before generator invocation.
- Publishing and non-dry-run operation require separate explicit controls.
- Existing Marketplace y-streams are skipped by the generator's idempotency guard.
- The release-controller job is optional and therefore does not block payload acceptance.

## Test strategy

The local fixture suite covers payload-version derivation, malformed and
missing metadata, `oc` and installer failures, RHCOS validation, publisher
safety gates, idempotent generator arguments, failure propagation, and the
nightly/release-controller configuration link.

`/pj-rehearse periodic-ci-openshift-release-main-nightly-5.1-rosa-marketplace-release`
complements fixtures by resolving a real candidate payload, running both
step-registry steps in CI, and verifying the pull-secret and payload extraction
paths. Publishing remains disabled, so this rehearsal cannot modify
Marketplace state.

## Ownership boundaries

| Area | Effective owner |
|---|---|
| `ci-operator/config/openshift/release/` | Technical Release Team |
| `ci-operator/jobs/openshift/release/` | Technical Release Team |
| `core-services/release-controller/_releases/` | Technical Release Team / DPTP |
| `ci-operator/step-registry/rosa/` | ROSA team, subject to nearer OWNERS files |
| `hack/` | Repository-root DPTP ownership unless a nearer OWNERS file exists |

## Publication enablement requirements

- Approved immutable digest or protected image-stream tag containing the generator.
- Reviewed staging AWS credentials and least-privilege permissions.
- Confirmed staging profile and generator CLI contract.
- Successful disabled rehearsal, staging dry run, and explicitly reviewed non-dry run.
- Agreed operational ownership, alerting, rollback, and duplicate policy.
