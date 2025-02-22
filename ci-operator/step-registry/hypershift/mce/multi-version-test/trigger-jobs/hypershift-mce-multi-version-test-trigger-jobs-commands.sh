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


eval "$(get_payload_list)"

SLEEP_TIME=10
job_count=1
for hub_version in "${!hub_to_mce[@]}"; do
    mce_versions="${hub_to_mce[$hub_version]}"

    for mce_version in $mce_versions; do
        guest_versions="${mce_to_guest[$mce_version]}"

        for guest_version in $guest_versions; do
            echo "HUB $hub_version, MCE $mce_version, HostedCluster $guest_version--------trigger job: ${guest_to_job_aws[$guest_version]}-----payload ${payload_list[$hub_version]}"
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