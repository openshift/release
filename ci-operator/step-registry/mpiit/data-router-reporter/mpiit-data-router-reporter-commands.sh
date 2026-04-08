#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail


function reportToDataRouter() {
    if [[ $REPORT_TO_DR == "true" ]]; then
        if [[ $REPORTPORTAL_CMP == "" ]]; then
            echo "Required variable 'REPORTPORTAL_CMP' is missing!"
            exit 1
        fi
      datarouter-openshift-ci
    fi
}

function extractOCPVersion() {
    # If OCP_VERSION is not set, we don't want to fail the entire launch report process
    # The version attribute is not essentially required, so extract it from the JOB_NAME
    if [[ -z "${OCP_VERSION}" ]]; then
        if [[ "${JOB_NAME}" =~ ocp-([0-9]+\.[0-9]+) ]]; then
            export OCP_VERSION="${BASH_REMATCH[1]}"
        else
            export OCP_VERSION="unknown"
        fi
    fi
    true
}

export DATAROUTER_RESULTS="${SHARED_DIR}/*.xml"
export REPORTPORTAL_APPLY_TFA="${APPLY_TFA}"
export REPORTPORTAL_CMP
export REPORTPORTAL_HOSTNAME
export REPORTPORTAL_PROJECT="lp-interop-dr_personal"
export REPORTPORTAL_LAUNCH_NAME="${REPORTPORTAL_CMP}"

extractOCPVersion

typeset version="${OCP_VERSION}"
typeset fips="${FIPS_ENABLED}"

REPORTPORTAL_LAUNCH_ATTRIBUTES="$(
    jq -nc \
        --arg jobName "${JOB_NAME}" \
        --arg buildID "${BUILD_ID}" \
        --arg ocpVer "${version}" \
        --arg rpCompName "${REPORTPORTAL_CMP}" \
        --arg fipsEnabled "${fips}" \
        '[
            {key: "job_name", value: $jobName},
            {key: "build_id", value: $buildID},
            {key: "ocp_release", value: $ocpVer},
            {key: "component_name", value: $rpCompName},
            {key: "fips_enabled", value: $fipsEnabled}
        ]'
)"
export REPORTPORTAL_LAUNCH_ATTRIBUTES

reportToDataRouter
