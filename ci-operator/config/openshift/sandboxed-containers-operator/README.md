# OpenShift Sandboxed Containers CI Configuration

This directory contains the ci-operator configuration used to generate OSC Prow
jobs. Set job-specific parameters in the ci-operator configuration
(`tests[].steps.env`) to override step defaults.

Change shared steps, chains, or workflows in the
[OSC step registry](../../../step-registry/sandboxed-containers-operator/README.md)
when their behavior needs to change.

Review the [OSC CI contribution guide](CONTRIBUTING.md)
for the intended workflow, its Mermaid step graph, and guidance on finding reusable
steps. If the workflow outline changes, follow the
[graph regeneration instructions](CONTRIBUTING.md#regenerating-the-step-graph).

## Downstream

The `__downstream` config variants define jobs that test downstream OSC builds.
Update the applicable variant's release and parameter overrides, such as
`KATA_RPM_VERSION`, then use `/pj-rehearse <job-name>` on the `openshift/release`
PR to rehearse the affected job.

Example overrides:

    releases:
      latest:
        release:
          # Use channel: stable/candidate
          channel: stable
          # Use version: "4.20", "4.21", ...
          version: "4.18"
    tests:
    - as: azure-ipi-kata
      steps:
        env:
          # Set RPM version and checksum
          # An test case will use that to check the expected operator
          # version is installed
          KATA_RPM_VERSION: 4.2.0-2.rhaos4.20.el9
          # Add sleep here if you need to do manual testing
          # connect to cluster and delete the sandboxed-containers-operator-post-wait pod when done
           SLEEP_DURATION: "0h"
    zz_generated_metadata:
      # Set a sensible variant name like "downstream-1.9-release-4.18" or so
      variant: downstream-release

## Tests

The shared `sandboxed-containers-operator-test` chain runs a sanity check by
default, then creates `${SHARED_DIR}/testsuites_gate`. If provisioning, OSC setup,
or the sanity check fails, the gate is absent and the post-phase suites skip.

Opt in to individual post-phase suites with `TESTS_<SUITE_NAME>_ENABLE`. See the
[testsuites README](../../../step-registry/sandboxed-containers-operator/testsuites/README.md)
for suite parameters and failure behavior.
