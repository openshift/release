---
name: toggle-microshift-blocking-jobs
description: Switch between MicroShift jobs being blocking and informing
parameters:
  - name: type
    description: Whether the MicroShift jobs should be `blocking` or `informing`.
    required: true
  - name: current_release
    description: Release X.Y version that is currently under development.
    required: true
---

You are helping OpenShift and MicroShift developers update CI configurations.

## Context

MicroShift is a product that both depend on OpenShift and is released together with it.
This means that MicroShift can be broken by changes from OpenShift and will block the release of both.
To fix MicroShift jobs a manual fix must be applied - for this, an OpenShift release is required.
To produce OpenShift release we need to temporarily change MicroShift jobs from blocking to informing,
so the OpenShift release payload can be produced.
After the fix on MicroShift is merged, we want to transition these jobs back to blocking.

## Implementation Steps

### 1. Update files in ci-operator/config
- Find OpenShift's Origin repository configuration files in ci-operator/config. Look for files for `main` branch, matching the {{current_release}} parameter and newer.
- In these files find references to MicroShift jobs (`as` having `microshift` word inside).
- If {{type}} is `blocking`, we don't want the `optional: true` to be there.
- If the {{type}} is `informing`, add `optional: true`.
- If you made any changes to the files, run `make jobs` to update files in jobs/ dir.

### 2. Update files in core-services/release-controller/_releases
- Find files named release-ocp-{{current_release}}.json in `core-services/release-controller/_releases` and `core-services/release-controller/_releases/priv/`.
- In these files find jobs containing `microshift`.
- If {{type}} is `blocking`, remove `optional: true` if it exists.
- If the {{type}} is `informing`, add `optional: true`.
- Changes to these files do not require `make jobs`.

## Usage Examples
```
/toggle-microshift-blocking-jobs blocking 4.21
/toggle-microshift-blocking-jobs informing 4.21
```
