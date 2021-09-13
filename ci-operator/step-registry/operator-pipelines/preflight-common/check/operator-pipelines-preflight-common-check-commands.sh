#!/usr/bin/env bash

# This step will execute preflight against the provided asset.
# https://github.com/redhat-openshift-ecosystem/openshift-preflight
#
# Expects env vars:
#    PREFLIGHT_ASSET_TYPE:  The asset type, which correlates with the 
#                           preflight policy that is to be executed.
#                           Options: container, operator
#    PREFLIGHT_TEST_ASSET:  The asset to test with the preflight utility.
#                           Must include the registry and the tag/digest.
#                           Ex. quay.io/example/some-container:0.0.1

# Check for the expected asset types, or otherwise fail.
rc=$([ "$PREFLIGHT_ASSET_TYPE" = "container" ] || [ "$PREFLIGHT_ASSET_TYPE" = "operator" ]; echo $?)
[ "$rc" -ne 0 ] && { echo "ERR An incorrect asset type was provided. Expecting 'container' or 'operator'."; exit 1 ;}

echo "Starting demo execution of preflight..."
ls -lha

# Tell preflight to log verbosely.
export PFLT_LOGLEVEL=trace
export PFLT_ARTIFACTS=${ARTIFACT_DIR}

# Sanity check: ensure preflight exists and execute it.
preflight check "${PREFLIGHT_ASSET_TYPE}" "${PREFLIGHT_TEST_ASSET}"

# Write logs from the current working directory to the artifacts directory defined by CI to extract them.
# results.json is in the working directory, but everything else is in a local ./artifacts directory, so
# we move all of those to the CI pipeline's artifact location.
# cp -a artifacts/* "${ARTIFACT_DIR}"/

echo "Ending demo execution of preflight..."
exit 0
