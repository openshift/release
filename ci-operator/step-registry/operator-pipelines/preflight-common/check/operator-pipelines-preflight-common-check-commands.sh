#!/usr/bin/env bash

# This step will execute preflight against the provided asset.
# https://github.com/redhat-openshift-ecosystem/openshift-preflight
#
# Expects env vars:
#    ASSET_TYPE:            The asset type, which correlates with the 
#                           preflight policy that is to be executed.
#                           Options: container, operator
#    TEST_ASSET:            The asset to test with the preflight utility.
#                           Must include the registry and the tag/digest.
#                           Ex. quay.io/example/some-container:0.0.1
#    PFLT_INDEXIMAGE:       The index image containing the bundle under test
#                           if testing an operator.
#    PFLT_LOGLEVEL          The log verbosity. One of "info", "error", "debug",
#                           "trace".
#    PFLT_ARTIFACTS         Where Preflight will write artifacts.

# Check for the expected asset types, or otherwise fail.
rc=$([ "$ASSET_TYPE" = "container" ] || [ "$ASSET_TYPE" = "operator" ]; echo $?)
[ "$rc" -ne 0 ] && { echo "ERR An incorrect asset type was provided. Expecting 'container' or 'operator'."; exit 1 ;}

# Go to a temporary directory to write
WORKDIR=$(mktemp -d)
cd "${WORKDIR}" || exit 2

echo "Starting preflight."
export PFLT_ARTIFACTS
export PFLT_INDEXIMAGE
export PFLT_LOGLEVEL

# Sanity check: ensure preflight exists and execute it.
preflight check "${ASSET_TYPE}" "${TEST_ASSET}"

# Write logs from the current working directory to the artifacts directory defined by CI to extract them.
# results.json is in the working directory, but everything else is in a local ./artifacts directory, so
# we move all of those to the CI pipeline's artifact location.
# cp -a artifacts/* "${ARTIFACT_DIR}"/

echo "Ending preflight."
exit 0
