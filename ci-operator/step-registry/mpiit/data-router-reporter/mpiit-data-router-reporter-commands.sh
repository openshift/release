#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Legacy backward compatibility. TODO: To be removed once all caller are migrated.
: "${LP_QE__CR__TS_NAME__PFX:=${REPORTPORTAL_CMP}}"

[ -n "${LP_QE__CR__TS_NAME__PFX}" ]

# If `OCP_VERSION` is not set, try to extract it form `JOB_NAME`.
if [ -z "${OCP_VERSION}" ]; then
    if [[ "${JOB_NAME}" =~ ocp-([0-9]+\.[0-9]+) ]]; then
        OCP_VERSION="${BASH_REMATCH[1]}"
    else
        OCP_VERSION="unknown"
    fi
fi

DATAROUTER_RESULTS="${SHARED_DIR}/*.xml" \
    REPORTPORTAL_LAUNCH_NAME="${LP_QE__CR__TS_NAME__PFX}" \
    REPORTPORTAL_LAUNCH_ATTRIBUTES="$(
        jq -nc \
            --arg jobName "${JOB_NAME}" \
            --arg buildID "${BUILD_ID}" \
            --arg ocpVer "${OCP_VERSION}" \
            --arg crCompName "${LP_QE__CR__TS_NAME__PFX}" \
            --arg fipsEnabled "${FIPS_ENABLED}" \
            '[
                {key: "job_name", value: $jobName},
                {key: "build_id", value: $buildID},
                {key: "ocp_release", value: $ocpVer},
                {key: "ComponentReadiness_ComponentName", value: $crCompName},
                {key: "fips_enabled", value: $fipsEnabled}
            ]'
    )" \
    datarouter-openshift-ci

true