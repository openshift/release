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
)
declare -A mce_to_guest=(
    [2.4]="4.14"
    [2.5]="4.14 4.15"
    [2.6]="4.14 4.15 4.16"
    [2.7]="4.14 4.15 4.16 4.17"
    [2.8]="4.14 4.15 4.16 4.17 4.18"
)
declare -A hub_to_mce=(
    [4.14]="2.4 2.5 2.6"
    [4.15]="2.5 2.6 2.7"
    [4.16]="2.6 2.7 2.8"
    [4.17]="2.7 2.8"
    [4.18]="2.8"
)

#TODO It needs improvement; it's only stable for now.
function get_payload_list() {
    declare -A payload_list
    local versions=("4.14" "4.15" "4.16" "4.17" "4.18")

    for version in "${versions[@]}"; do
        image=$(curl -s https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-$version/release.txt | awk '/Pull From/ {print $3}')
        payload_list["$version"]=$image
    done

    declare -p payload_list
}

# Function to trigger a Prow Job using the Gangway API.
# This function attempts to trigger a Prow Job and retries up to 10 times if the API is unavailable.
# Parameters:
#   $1 - Job name (_job_name)
#   $2 - MCE version (_mce_version)
#   $3 - Management cluster payload (_mgmt_payload)
function trigger_prow_job() {
    local GANGWAY_API='https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com'

    local _job_name="$1"
    local _mce_version="$2"
    local _mgmt_payload="$3"

    # Set maximum retry attempts and retry interval (seconds)
    local max_retries=2
    local retry_interval=10

    # Construct POST request, payload, mce version
    DATA=$(jq -n --arg mce_version "$_mce_version" \
        --arg release_image "$_mgmt_payload" \
        '{job_execution_type: "1", pod_spec_options: {envs: {MULTISTAGE_PARAM_OVERRIDE_MCE_VERSION: $mce_version, RELEASE_IMAGE_LATEST: $release_image}}}')
    set +x
    for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
        response=$(curl -s -X POST -d "${DATA}" \
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


eval "$(get_payload_list)"

SLEEP_TIME=10
job_count=1
for hub_version in "${!hub_to_mce[@]}"; do
    mce_versions="${hub_to_mce[$hub_version]}"

    for mce_version in $mce_versions; do
        guest_versions="${mce_to_guest[$mce_version]}"

        for guest_version in $guest_versions; do
            echo "HUB $hub_version, MCE $mce_version, HostedCluster $guest_version--------trigger job: ${guest_to_job_aws[$guest_version]}-----payload ${payload_list[$hub_version]}"

            result=$(trigger_prow_job "${guest_to_job_aws[$guest_version]}" "$mce_version" "${payload_list[$hub_version]}")
            job_id=$(echo "$result" | grep "JOB_ID###" | cut -d'#' -f4 || true)
            echo "$job_id"

            ((job_count++))

            if ((job_count > JOB_PARALLEL)); then
                echo "Reached $JOB_PARALLEL jobs, sleeping for $SLEEP_TIME seconds..."
                sleep "$SLEEP_TIME"
                job_count=1
            fi
        done
    done
done

if ((job_count > 1)); then
    echo "Final batch, sleeping for $SLEEP_TIME seconds..."
    sleep "$SLEEP_TIME"
fi