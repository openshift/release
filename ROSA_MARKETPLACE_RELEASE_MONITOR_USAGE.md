# ROSA Marketplace Release: Usage and Covered Cases

## Current operating mode

Release-controller invokes `rosa-marketplace-release` for a concrete OpenShift
payload and supplies that payload through `RELEASE_IMAGE_LATEST`. The detector
derives the OCP y-stream and RHCOS metadata from the payload. Marketplace
publishing is disabled, so the publisher currently exits successfully without
looking for or invoking the generator.

Do not enable publishing merely by changing `MARKETPLACE_PUBLISH_ENABLED`. The
job still needs an approved generator image and mounted staging credentials.

## Runtime flow

```text
release-controller payload
  -> optional rosa-marketplace-release ProwJob
  -> inspect RELEASE_IMAGE_LATEST
  -> derive OCP y-stream
  -> extract installer and RHCOS metadata
  -> disabled publisher no-op
```

The job registration is maintained in two versioned inputs:

```text
ci-operator/config/openshift/release/
  openshift-release-main__nightly-5.1.yaml

core-services/release-controller/_releases/
  release-ocp-5.1.json
```

The standard OCP pre-branch automation carries these entries forward when a
new y-stream is created. There is no fixed `TARGET_OCP_Y_STREAM` in the job or
script. Review the automated pre-branch change to confirm both entries were
copied; do not add a runtime version switch.

## Running local validation

Run the deterministic suite:

```bash
bash hack/rosa-marketplace-release-monitor-tests.sh
```

The suite does not need a cluster, network, registry, or AWS credentials. It
uses fake `oc`, installer, and generator commands.

Covered cases:

| Area | Cases |
|---|---|
| Payload input | Exact payload is recorded; missing or whitespace-containing input fails |
| Version derivation | Full nightly version produces the correct y-stream; missing, malformed, or invalid versions fail |
| Payload inspection | `oc adm release info` failure propagates |
| RHCOS extraction | Version and regional AMI succeed; missing fields and installer failure propagate |
| Publisher disabled | Ready input exits successfully without generator discovery |
| Publisher safety | Legacy/non-ready state and production environment fail |
| Idempotency | Generator receives `--skip-if-version-exists` and duplicate AMI copying remains disabled |
| Dry run | Dry run is default; explicit non-dry-run arguments are covered |
| Failure propagation | Generator failure fails the step |
| CI contract | Versioned nightly job and optional release-controller registration reference the same ProwJob |

After configuration changes, run the repository checks:

```bash
make registry-metadata
make jobs
make ci-operator-checkconfig
make validate-step-registry
make checkconfig
git diff --check
```

Container-backed targets require a working local container runtime. Report any
environmental limitation instead of treating it as a successful validation.

## Prow rehearsal

On the pull request, comment:

```text
/pj-rehearse periodic-ci-openshift-release-main-nightly-5.1-rosa-marketplace-release
```

The rehearsal should start:

```text
periodic-ci-openshift-release-main-nightly-5.1-rosa-marketplace-release
```

Expected behavior:

1. ci-operator resolves the current 5.1 nightly candidate.
2. `RELEASE_IMAGE_LATEST` is available to the detector.
3. The detector inspects that payload and extracts its installer.
4. RHCOS version and the `us-east-1` AMI are validated.
5. The publisher logs a disabled no-op and exits successfully.

Publishing remains disabled during rehearsal, so the job does not need AWS
Marketplace credentials and cannot change Marketplace state.

## Reading results

The primary detector state is:

```text
${SHARED_DIR}/rosa-marketplace-release-state
```

Its only successful value is `ready`. Inspect these associated files:

```text
rosa-marketplace-ocp-version
rosa-marketplace-payload-tag
rosa-marketplace-payload-pullspec
rosa-marketplace-rhcos-version
rosa-marketplace-rhcos-ami
```

The release-info and CoreOS stream JSON documents are retained in
`ARTIFACT_DIR`. Never include pull-secret or AWS credential contents in a bug
report.

## Typical cases

### New payload for an enabled y-stream

Release-controller starts the optional job with the exact payload. The detector
derives the y-stream without calling release-controller APIs. With publication
disabled, the job validates inputs and safely stops.

### Later payload for the same y-stream

The same job runs with a different immutable payload. When publication is
eventually enabled, `--skip-if-version-exists` tells the generator to return
success if that OCP y-stream already exists in Marketplace.

### New OCP y-stream

The OCP pre-branch automation creates the next versioned nightly and
release-controller configurations. Confirm that `rosa-marketplace-release` is
present in both generated files. No detector, fixture, or environment-variable
change is needed.

### Y-stream not enabled for this ROSA workflow

Do not register `rosa-marketplace-release` in that stream's release-controller
definition. The release-controller configuration is the policy boundary; the
runtime script does not guess ROSA support from version numbers.

### Missing or malformed payload metadata

The detector fails. A release-controller invocation always represents a
concrete payload, so there is no normal `wait:*` lifecycle state.

### Publishing remains disabled

Expected publisher log:

```text
No action: publishing is disabled for ocp_version=<major.minor>
```

The generator executable is not discovered or invoked.

### Enabled staging dry run

After every enablement prerequisite is satisfied, the publisher invokes:

```text
marketplace-release-generator release
  --environment staging
  --ocp-version <major.minor>
  --rhcos-version <rhcos-release>
  --aws-profile <profile>
  --copy-if-duplicate=false
  --skip-if-version-exists
  --timeout <duration>
  --dry-run
```

Production is intentionally rejected.

## Fixture maintenance

Fixtures model the payload, installer, and publisher contracts. They are not
snapshots for individual OCP releases. Update them only when a consumed schema
changes, behavior changes, or a production defect needs a regression test. A
new y-stream alone does not require fixture changes.

## Troubleshooting

| Symptom | Check first |
|---|---|
| `RELEASE_IMAGE_LATEST is required` | Confirm ci-operator release input or release-controller invocation |
| Payload version is invalid | Inspect `rosa-marketplace-release-info.json` metadata version |
| Payload inspection/extraction fails | Verify pull-secret mount, registry access, and `oc` availability |
| RHCOS version or AMI missing | Run the payload's installer with `coreos print-stream-json` |
| Publisher reports missing output | Confirm detector completed with `ready` and both steps share `SHARED_DIR` |
| Generator not found | Publishing was enabled without an approved generator image |
| Duplicate y-stream is attempted | Confirm the generator supports and receives `--skip-if-version-exists` |

## Publishing enablement checklist

- Use an approved immutable or protected image containing the generator.
- Mount reviewed staging AWS credentials with least privilege.
- Verify the AWS profile and Marketplace product configuration.
- Keep `MARKETPLACE_ENVIRONMENT=staging`.
- Run and review a dry-run rehearsal.
- Agree on duplicate handling, rollback, alerting, and operational ownership.
- Obtain ROSA, Technical Release Team, and DPTP reviews for their owned areas.
