This directory contain the ci-operator configuration files to generate the Prow jobs for the Openshift Sandboxed Containers (OSC) operator.

## Downstream

The jobs in this category are used to test the downstream builds of OSC. In
this repo we host the base-workflow files marked with `__downstream` in their
name. One should copy those into per-variant workflow and send a PR, keep
updating the ``KATA_RPM_VERSIONS`` and running the jobs via `/pj-rehearse`. The
usual changes to those files are::

    base_images:
      tests-private:
        # Always use the latest provided by "skopeo list-tags docker://registry.ci.openshift.org/ci/tests-private"
        tag: "4.20"
    releases:
      latest:
        release:
          # Use channel: stable/candidate
          channel: stable
          # Use version: "4.18", "4.19", ...
          version: "4.18"
    tests:
    - as: azure-ipi-kata
      steps:
        env:
          # Set RPM version and checksum
          # An test case will use that to check the expected operator
          # version is installed
          EXPECTED_OPERATOR_VERSION: 1.9.0
          KATA_RPM_VERSION: "3.13.0-1.rhaos4.18.el9"
          # Add sleep here if you need to do manual testing
          # connect to cluster and delete the cucushift-installer-wait pod when done
          SLEEP_DURATION: "0"
          # Select the testsuit based on filters+scenarios
          TEST_FILTERS: ~DisconnectedOnly&;~Disruptive&
          TEST_SCENARIOS: C00102
          TEST_TIMEOUT: "75"
    zz_generated_metadata:
      # Set a sensible variant name like "downstream-1.9-release-4.18" or so
      variant: downstream-release

The downstream jobs use custom steps, chains and workflows hosted at [here](../../../step-registry/sandboxed-containers-operator/). Please refer to [their documentation](../../../step-registry/sandboxed-containers-operator/README.md) for further information.
