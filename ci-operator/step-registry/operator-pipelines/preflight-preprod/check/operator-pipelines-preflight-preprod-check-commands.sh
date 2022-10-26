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
#    PUBLISH_ARTIFACTS      Whether to publish preflight's plaintext artifacts/*, results.json, 
#                           and preflight.log to this job's log on prow.ci.openshift.org.
#                           Options: true, false

# Check for the expected asset types, or otherwise fail.
rc=$([ "${ASSET_TYPE}" == "container" ] || [ "${ASSET_TYPE}" == "operator" ]; echo $?)
[ "$rc" -ne 0 ] && { echo "ERR An incorrect asset type was provided. Expecting 'container' or 'operator'."; exit 1 ;}

# Go to a temporary directory to write
WORKDIR=$(mktemp -d)
cd "${WORKDIR}" || exit 2

preflight_targz_file="${SHARED_DIR}/preflight.tar.gz"
preflight_stdout_file="${WORKDIR}/preflight.stdout"
preflight_stderr_file="${WORKDIR}/preflight.stderr"

export PFLT_ARTIFACTS
export PFLT_INDEXIMAGE
export PFLT_LOGLEVEL

if [ -f "${SHARED_DIR}/decrypted_config.json" ]; then
    export PFLT_DOCKERCONFIG="${SHARED_DIR}/decrypted_config.json"
fi

echo "Running Preflight."
preflight check "${ASSET_TYPE}" "${TEST_ASSET}" > "${preflight_stdout_file}" 2> "${preflight_stderr_file}"

if [ "${PUBLISH_ARTIFACTS}" == "true" ]; then 
    echo "PUBLIC_ARTIFACTS is set to true. Publishing all artifacts."
    cp -a "${PFLT_ARTIFACTS}" "${ARTIFACT_DIR}"/
    cp -a preflight.log "${ARTIFACT_DIR}"/    
    cp -a "${preflight_stdout_file}" "${ARTIFACT_DIR}"/
    cp -a "${preflight_stderr_file}" "${ARTIFACT_DIR}"/
fi

echo "Placing assets into ${preflight_targz_file} for any future CI tasks."
# assumes we're in WORKDIR and strips full paths where appropriate.
tar czvf "${preflight_targz_file}" "$PFLT_ARTIFACTS" preflight.log "$(basename "${preflight_stdout_file}")"  "$(basename "${preflight_stderr_file}")"

echo "Preflight execution completed."
exit 0
