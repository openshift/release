#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

export SHARED_DIR=${SHARED_DIR:-/tmp/shared_dir}
export ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
export HOSTEDCLUSTER_PLATFORM=${HOSTEDCLUSTER_PLATFORM:-"aws"}
export JOB_PARALLEL=${JOB_PARALLEL:-"5"}
export CHECK_INTERVAL=${CHECK_INTERVAL:-300}
export CHECK_TIMEOUT=${CHECK_TIMEOUT:-18000}

TOKEN_PATH=${TOKEN_PATH:-/etc/mce-prow-gangway-credentials/token}
GANGWAY_API=${GANGWAY_API:-"https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com"}

# Each MCE supports the latest three HostedCluster versions
declare -A mce_to_guest=(
    [2.8]="4.16 4.17 4.18"
    [2.9]="4.17 4.18 4.19"
    [2.10]="4.18 4.19 4.20"
    [2.11]="4.19 4.20 4.21"
    [2.17]="4.20 4.21 4.22"
)

# Each MCE is available on the latest hub version and two versions back
declare -A hub_to_mce=(
    [4.18]="2.8 2.9 2.10"
    [4.19]="2.9 2.10 2.11"
    [4.20]="2.10 2.11 2.17"
    [4.21]="2.11 2.17"
    [4.22]="2.17"
)

function get_payload_list() {
    declare -A payload_list

    # Get all guest versions and the release image for each guest version
    for version in $(echo "${mce_to_guest[@]}" | tr ' ' '\n' | sort -uV); do
        image=$(curl -s "https://openshift-release.apps.ci.l2s4.p1.openshiftapps.com/api/v1/releasestream/${version}.0-0.nightly/latest" | jq -r '.pullSpec')
        payload_list["$version"]=$image
    done

    declare -p payload_list
}

# Function to trigger a Prow Job using the Gangway API.
# This function attempts to trigger a Prow Job and retries up to 10 times if the API is unavailable.
# Parameters:
#   $1 - Job name (_job_name)
#   $2 - HTTP POST data (_http_post_data)
function trigger_prow_job() {
    local GANGWAY_API='https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com'

    local _job_name="$1"
    local _http_post_data="$2"

    # Set maximum retry attempts and retry interval (seconds)
    local max_retries=30
    local retry_interval=10

    set +x
    for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
        response=$(curl -s -X POST -d "${_http_post_data}" \
            -H "Authorization: Bearer $(cat "${TOKEN_PATH}")" \
            "${GANGWAY_API}/v1/executions/${_job_name}" \
            -w "%{http_code}")

        json_body=$(echo "$response" | sed '$d')    # Extract JSON response body
        http_status=$(echo "$response" | tail -n 1) # Extract HTTP status code

        if [ "$http_status" -eq 200 ]; then
            echo "JOB_ID###$(jq -r '.id' <<< "$json_body")###"
            set -x
            return 0
        else
            (set -x; echo "[$retry_count/$max_retries] Gangway API not available (HTTP $response). Retrying in $retry_interval sec...")
            sleep "$retry_interval"
        fi
    done
    set -x
    echo "Gangway API is still not available after $max_retries retries. Aborting." && return 0
}

function wait_for_jobs() {
    local job_list_file="$1"
    local max_retries=30
    local retry_interval=10
    local start_time
    start_time=$(date +%s)

    cp "$job_list_file" /tmp/job_list_pending

    while true; do
        true > /tmp/job_list_next_pending

        while IFS= read -r line; do
            local job_id
            job_id=$(echo "$line" | awk -F'JOB_ID=' '{print $2}' | tr -d ' ')
            local prefix
            prefix=$(echo "$line" | sed 's/, *JOB_ID=.*//')

            if [ -z "$job_id" ]; then
                echo "${prefix}, JOB_URL=, JOB_STATUS=TriggerFailed" >> "${SHARED_DIR}/job_list"
                continue
            fi

            local job_status=""
            local job_url=""
            local http_status=""
            set +x
            for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
                response=$(curl -s -X GET -H "Authorization: Bearer $(cat "${TOKEN_PATH}")" \
                    "${GANGWAY_API}/v1/executions/${job_id}" -w "%{http_code}")

                json_body=$(echo "$response" | sed '$d')
                http_status=$(echo "$response" | tail -n 1)

                if [ "$http_status" -eq 200 ]; then
                    job_status=$(jq -r '.job_status' <<< "$json_body")
                    if [ "$job_status" == "null" ] || [ -z "$job_status" ]; then
                        job_status="other"
                    fi
                    job_url=$(jq -r '.job_url' <<< "$json_body")
                    break
                else
                    echo "[$retry_count/$max_retries] Gangway API not available (HTTP $http_status). Retrying in $retry_interval sec..."
                    sleep "$retry_interval"
                fi
            done
            set -x

            if [ "$http_status" -ne 200 ]; then
                echo "${prefix}, JOB_URL=, JOB_STATUS=QueryNotFound" >> "${SHARED_DIR}/job_list"
            elif [ "$job_status" == "PENDING" ] || [ "$job_status" == "TRIGGERED" ]; then
                echo "$line" >> /tmp/job_list_next_pending
            else
                echo "${prefix}, JOB_URL=${job_url}, JOB_STATUS=${job_status}" >> "${SHARED_DIR}/job_list"
            fi
        done < /tmp/job_list_pending

        if [ ! -s /tmp/job_list_next_pending ]; then
            echo "All jobs have completed."
            break
        fi

        local elapsed=$(( $(date +%s) - start_time ))
        if [ "$elapsed" -ge "$CHECK_TIMEOUT" ]; then
            echo "Timeout reached (${CHECK_TIMEOUT}s). Marking remaining jobs as PENDING."
            while IFS= read -r line; do
                local prefix
                prefix=$(echo "$line" | sed 's/, *JOB_ID=.*//')
                echo "${prefix}, JOB_URL=, JOB_STATUS=PENDING" >> "${SHARED_DIR}/job_list"
            done < /tmp/job_list_next_pending
            break
        fi

        local pending_count
        pending_count=$(wc -l < /tmp/job_list_next_pending)
        echo "${pending_count} job(s) still pending. Rechecking in ${CHECK_INTERVAL}s..."
        sleep "${CHECK_INTERVAL}"
        mv /tmp/job_list_next_pending /tmp/job_list_pending
    done
}

function generate_junit_xml() {
    total_tests=$(awk 'END {print NR}' "${SHARED_DIR}/job_list")
    failures=$(grep -c "JOB_STATUS=FAILURE" "${SHARED_DIR}/job_list" || true)
    skipped=$(( $(grep -c "JOB_STATUS=QueryNotFound" "${SHARED_DIR}/job_list" || true) + $(grep -c "JOB_STATUS=TriggerFailed" "${SHARED_DIR}/job_list" || true) ))

    cat << EOF > "${ARTIFACT_DIR}/junit-multi-version-result.xml"
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="mce multi version test on ${HOSTEDCLUSTER_PLATFORM}" tests="${total_tests}" skipped="${skipped}" failures="${failures}" time="0">
    <link/>
    <script/>
EOF
    while IFS= read -r line; do
        testcase_name=$(echo "$line" | sed -n 's/^\([^,]*, [^,]*, [^,]*, [^,]*\).*/\1/p')
        job_status=$(echo "$line" | sed -n 's/.*JOB_STATUS=\([^,]*\).*/\1/p')

        if [[ -z "$job_status" ]]; then
            echo "    <testcase name=\"$testcase_name\" time=\"0\">" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
            echo "        <failure message=\"\">Missing JOB_STATUS</failure>" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
            echo "    </testcase>" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
        elif [[ "$job_status" == "FAILURE" ]]; then
            echo "    <testcase name=\"$testcase_name\" time=\"0\">" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
            echo "        <failure message=\"Job failed\">$line</failure>" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
            echo "    </testcase>" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
        elif [[ "$job_status" == "QueryNotFound" || "$job_status" == "TriggerFailed" || "$job_status" == "PENDING" ]]; then
            echo "    <testcase name=\"$testcase_name\" time=\"0\">" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
            echo "        <skipped message=\"$job_status\">$line</skipped>" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
            echo "    </testcase>" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
        else
            echo "    <testcase name=\"$testcase_name\" time=\"0\"/>" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
        fi
    done < "${SHARED_DIR}/job_list"
    echo "</testsuite>" >> "${ARTIFACT_DIR}/junit-multi-version-result.xml"
}


eval "$(get_payload_list)"

true > /tmp/wave_jobs
job_count=0
for hub_version in "${!hub_to_mce[@]}"; do
    mce_versions="${hub_to_mce[$hub_version]}"

    for mce_version in $mce_versions; do
        guest_versions="${mce_to_guest[$mce_version]}"
        job_name=""
        for guest_version in $guest_versions; do
            case $HOSTEDCLUSTER_PLATFORM in
                aws)
                    job_name="periodic-ci-openshift-hypershift-release-${guest_version}-periodics-mce-e2e-aws-critical"
                    post_data=$(jq -n --arg mce_version "$mce_version" \
                        --arg release_image "${payload_list[$hub_version]}" \
                        '{job_execution_type: "1", pod_spec_options: {envs: {MULTISTAGE_PARAM_OVERRIDE_MCE_VERSION: $mce_version, RELEASE_IMAGE_LATEST: $release_image, MULTISTAGE_PARAM_OVERRIDE_TEST_EXTRACT: "true"}}}')
                    result=$(trigger_prow_job "$job_name" "$post_data")
                    ;;
                agent)
                    #todo
                    ;;
                *)
                    echo "not support ${HOSTEDCLUSTER_PLATFORM}"
                    ;;
            esac
            job_id=$(echo "$result" | grep "JOB_ID###" | cut -d'#' -f4 || true)
            echo "HUB=${hub_version}, MCE=${mce_version}, HostedCluster=${guest_version}, PLATFORM=${HOSTEDCLUSTER_PLATFORM}, JOB=${job_name}, JOB_ID=${job_id}" >> "/tmp/wave_jobs"

            ((++job_count))

            if ((job_count >= JOB_PARALLEL)); then
                echo "Wave of ${job_count} job(s) triggered. Waiting for completion..."
                wait_for_jobs /tmp/wave_jobs
                true > /tmp/wave_jobs
                job_count=0
            fi
        done
    done
done

if ((job_count > 0)); then
    echo "Final wave of ${job_count} job(s) triggered. Waiting for completion..."
    wait_for_jobs /tmp/wave_jobs
fi

generate_junit_xml
cat "${SHARED_DIR}/job_list" > "$ARTIFACT_DIR/job_list"