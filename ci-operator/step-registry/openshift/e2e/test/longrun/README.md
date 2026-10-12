# openshift-e2e-test-longrun

This step is a copy of the `openshift-e2e-test` step with the sole purpose of allowing longer test executions without modifying the original step's timeout.

## Purpose

The only difference from the original `openshift-e2e-test` step is the extended timeout (22h vs 4h). This allows long-running test suites to complete without hitting timeout limits.

## Implementation

- **Commands**: Symlinked to `../openshift-e2e-test-commands.sh` to ensure identical behavior
- **Configuration**: Copied from `openshift-e2e-test-ref.yaml` with only the timeout modified

## Maintenance

**IMPORTANT**: This step should be kept in sync with the original `openshift-e2e-test` step. Any changes to the original step's environment variables, dependencies, or documentation should be reflected here (except for the timeout value).

The commands script is symlinked, so it automatically stays in sync with the original implementation.
