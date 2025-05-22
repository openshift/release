#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

declare -A guest_to_job_aws=(
    [4.14]="periodic-ci-openshift-hypershift-release-4.14-periodics-mce-e2e-aws-critical"
    [4.15]="periodic-ci-openshift-hypershift-release-4.15-periodics-mce-e2e-aws-critical"
    [4.16]="periodic-ci-openshift-hypershift-release-4.16-periodics-mce-e2e-aws-critical"
    [4.17]="periodic-ci-openshift-hypershift-release-4.17-periodics-mce-e2e-aws-critical"
    [4.18]="periodic-ci-openshift-hypershift-release-4.18-periodics-mce-e2e-aws-critical"
    [4.19]="periodic-ci-openshift-hypershift-release-4.19-periodics-mce-e2e-aws-critical"
)
declare -A mce_to_guest=(
    [2.4]="4.14"
    [2.5]="4.14 4.15"
    [2.6]="4.14 4.15 4.16"
    [2.7]="4.14 4.15 4.16 4.17"
    [2.8]="4.14 4.15 4.16 4.17 4.18"
    [2.9]="4.15 4.16 4.17 4.18 4.19"
)
declare -A hub_to_mce=(
    [4.14]="2.4 2.5 2.6"
    [4.15]="2.5 2.6 2.7"
    [4.16]="2.6 2.7 2.8"
    [4.17]="2.7 2.8 2.9"
    [4.18]="2.8 2.9"
    [4.19]="2.9"
)

function get_payload_list() {
    declare -A payload_list
    local versions=("4.14" "4.15" "4.16" "4.17" "4.18")

    for version in "${versions[@]}"; do
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
    local max_retries=2
    local retry_interval=10

    set +x
    for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
        response=$(curl -s -X POST -d "${_http_post_data}" \
            -H "Authorization: Bearer $(cat /etc/mce-prow-gangway-credentials/token)" \
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

function check_jobs() {
    local GANGWAY_API='https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com'

    local max_retries=2
    local retry_interval=10

    while IFS=, read -r HUB MCE HostedCluster PLATFORM JOB JOB_ID; do
        JOB_ID=$(echo "$JOB_ID" | awk -F= '{print $2}' || true)

        if [ -z "$JOB_ID" ]; then
            job_status="TriggerFailed"
            job_url=""
        else
            set +x
            for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
                response=$(curl -s -X GET -H "Authorization: Bearer $(cat /etc/mce-prow-gangway-credentials/token)" \
                    "${GANGWAY_API}/v1/executions/${JOB_ID}" -w "%{http_code}")

                json_body=$(echo "$response" | sed '$d')    # Extract JSON response body
                http_status=$(echo "$response" | tail -n 1) # Extract HTTP status code

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
                job_status="QueryNotFound"
                job_url=""
            fi
        fi
        echo "$HUB, $MCE, $HostedCluster, $PLATFORM, $JOB, JOB_URL=${job_url}, JOB_STATUS=${job_status}" >> "${SHARED_DIR}/job_list"
    done < "/tmp/job_list"
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

job_count=1
for hub_version in "${!hub_to_mce[@]}"; do
    mce_versions="${hub_to_mce[$hub_version]}"

    for mce_version in $mce_versions; do
        guest_versions="${mce_to_guest[$mce_version]}"

        for guest_version in $guest_versions; do
            case $HOSTEDCLUSTER_PLATFORM in
                aws)
                    post_data=$(jq -n --arg mce_version "$mce_version" \
                        --arg release_image "${payload_list[$hub_version]}" \
                        '{job_execution_type: "1", pod_spec_options: {envs: {MULTISTAGE_PARAM_OVERRIDE_MCE_VERSION: $mce_version, RELEASE_IMAGE_LATEST: $release_image, MULTISTAGE_PARAM_OVERRIDE_TEST_EXTRACT: "true"}}}')
                    result=$(trigger_prow_job "${guest_to_job_aws[$guest_version]}" "$post_data")
                    ;;
                agent)
                    #todo
                    ;;
                *)
                    echo "not support ${HOSTEDCLUSTER_PLATFORM}"
                    ;;
            esac
            job_id=$(echo "$result" | grep "JOB_ID###" | cut -d'#' -f4 || true)
            echo "HUB=${hub_version}, MCE=${mce_version}, HostedCluster=${guest_version}, PLATFORM=${HOSTEDCLUSTER_PLATFORM}, JOB=${guest_to_job_aws[$guest_version]}, JOB_ID=${job_id}" >> "/tmp/job_list"

            ((job_count++))

            if ((job_count > JOB_PARALLEL)); then
                echo "Reached $JOB_PARALLEL jobs, sleeping for ${JOB_DURATION} seconds..."
                sleep "${JOB_DURATION}"
                job_count=1
            fi
        done
    done
done

if ((job_count > 1)); then
    echo "Final batch, sleeping for ${JOB_DURATION} seconds..."
    sleep "${JOB_DURATION}"
fi

check_jobs
generate_junit_xml
cat "${SHARED_DIR}/job_list" > "$ARTIFACT_DIR/job_list"