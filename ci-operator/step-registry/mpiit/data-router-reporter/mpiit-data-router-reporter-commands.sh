#!/bin/bash
set -euo pipefail

# Legacy backward compatibility. TODO: To be removed once all caller are migrated.
: "${DR__RP__CR_COMP_NAME:=${REPORTPORTAL_CMP}}"

[ -n "${DR__RP__CR_COMP_NAME}" ]

# If `OCP_VERSION` is not set, try to extract it form `JOB_NAME`.
if [ -z "${OCP_VERSION}" ]; then
    if [[ "${JOB_NAME}" =~ ocp-([0-9]+\.[0-9]+) ]]; then
        OCP_VERSION="${BASH_REMATCH[1]}"
    else
        OCP_VERSION="unknown"
    fi
fi

launch_attrs="$(
    jq -nc \
        --arg jobName "${JOB_NAME}" \
        --arg buildID "${BUILD_ID}" \
        --arg ocpVer "${OCP_VERSION}" \
        --arg crCompName "${DR__RP__CR_COMP_NAME}" \
        --arg fipsEnabled "${FIPS_ENABLED}" \
        '[
            {key: "job_name", value: $jobName},
            {key: "build_id", value: $buildID},
            {key: "ocp_release", value: $ocpVer},
            {key: "ComponentReadiness_ComponentName", value: $crCompName},
            {key: "fips_enabled", value: $fipsEnabled}
        ]'
)"

MAX_RETRIES=5
RETRY_INTERVAL=120

for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
    if DATAROUTER_RESULTS="${SHARED_DIR}/*.xml" \
        REPORTPORTAL_LAUNCH_NAME="${DR__RP__CR_COMP_NAME}" \
        REPORTPORTAL_LAUNCH_ATTRIBUTES="${launch_attrs}" \
        datarouter-openshift-ci; then
        echo "INFO: Data Router upload succeeded on attempt ${attempt}"
        exit 0
    fi
    if (( attempt < MAX_RETRIES )); then
        echo "WARNING: Data Router upload failed (attempt ${attempt}/${MAX_RETRIES}), retrying in ${RETRY_INTERVAL}s..."
        sleep "${RETRY_INTERVAL}"
    fi
done
echo "ERROR: Data Router upload failed after ${MAX_RETRIES} attempts"
exit 1
