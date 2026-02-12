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

export DATAROUTER_RESULTS="${SHARED_DIR}/*.xml"
export OCP_VERSION
export REPORTPORTAL_APPLY_TFA="${APPLY_TFA}"
export REPORTPORTAL_CMP
export REPORTPORTAL_HOSTNAME
export REPORTPORTAL_PROJECT="lp-interop-dr_personal"
export REPORTPORTAL_LAUNCH_NAME="${REPORTPORTAL_CMP}"

REPORTPORTAL_LAUNCH_ATTRIBUTES="$(
    jq -nc \
        --arg jobName "${JOB_NAME}" \
        --arg buildID "${BUILD_ID}" \
        --arg ocpVer "${OCP_VERSION}" \
        --arg rpCompName "${REPORTPORTAL_CMP}" \
        '[
            {key: "job_name", value: $jobName},
            {key: "build_id", value: $buildID},
            {key: "ocp_release", value: $ocpVer},
            {key: "component_name", value: $rpCompName}
        ]'
)"
export REPORTPORTAL_LAUNCH_ATTRIBUTES

reportToDataRouter
