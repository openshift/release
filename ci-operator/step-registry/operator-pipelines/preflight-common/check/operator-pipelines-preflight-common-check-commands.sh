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
#    PUBLISH_ARTIFACTS      Whether to publish preflight artifacts/*, results.json, and 
#                           preflight.log to this job's log on prow.ci.openshift.org.
#                           Options: true, false

# Check for the expected asset types, or otherwise fail.
rc=$([ "${ASSET_TYPE}" == "container" ] || [ "${ASSET_TYPE}" == "operator" ]; echo $?)
[ "$rc" -ne 0 ] && { echo "ERR An incorrect asset type was provided. Expecting 'container' or 'operator'."; exit 1 ;}

# Go to a temporary directory to write
WORKDIR=$(mktemp -d)
cd "${WORKDIR}" || exit 2

echo "Starting preflight."
export PFLT_ARTIFACTS
export PFLT_INDEXIMAGE
export PFLT_LOGLEVEL

preflight check "${ASSET_TYPE}" "${TEST_ASSET}" > "${WORKDIR}/preflight.stdout"

if [ "${PUBLISH_ARTIFACTS}" == "true" ]; then 
    cp -a "${PFLT_ARTIFACTS}" "${ARTIFACT_DIR}"/
    cp -a preflight.log "${ARTIFACT_DIR}"/    
    cp -a "${WORKDIR}/preflight.stdout" "${ARTIFACT_DIR}"/
fi

echo "Ending preflight."
exit 0
