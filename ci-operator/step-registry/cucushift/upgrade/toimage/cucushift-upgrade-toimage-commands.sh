#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Check if a build is signed
function check_signed() {
    local digest algorithm hash_value response
    digest="$(echo "${target}" | cut -f2 -d@)"
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    response=$(curl --silent --output /dev/null --write-out %"{http_code}" "https://mirror2.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
    if (( response == 200 )); then
        echo "${target} is signed" && return 0
    else
        echo "Seem like ${target} is not signed" && return 1
    fi
}

# Check if admin ack is required before upgrade
function admin_ack() {
    if [[ "${source_minor_version}" -eq "${target_minor_version}" ]]; then
        echo "Upgrade between z-stream version does not require admin ack" && return
    fi   
    
    local out; out="$(oc -n openshift-config-managed get configmap admin-gates -o json | jq -r ".data")"
    if [[ ${out} != *"ack-4.${source_minor_version}"* ]]; then
        echo "Admin ack not required" && return
    fi        
    
    echo "Require admin ack"
    local wait_time_loop_var=0 ack_data 
    ack_data="$(echo ${out} | awk '{print $2}' | cut -f2 -d\")" && echo "Admin ack patch data is: ${ack_data}"
    oc -n openshift-config patch configmap admin-acks --patch '{"data":{"'"${ack_data}"'": "true"}}' --type=merge
    
    echo "Admin-acks patch gets started"
            
    echo -e "sleep 5 min wait admin-acks patch to be valid...\n"
    while (( wait_time_loop_var < 5 )); do
        sleep 1m
        echo -e "wait_time_passed=${wait_time_loop_var} min.\n"
        if ! oc adm upgrade | grep "AdminAckRequired"; then
            echo -e "Admin-acks patch PASSED\n"
            return 0              
        else
            echo -e "Admin-acks patch still in processing, waiting...\n"
        fi
        (( wait_time_loop_var += 1 ))
    done
    if (( wait_time_loop_var >= 5 )); then
        echo >&2 "Timed out waiting for admin-acks completing, exiting" && return 1
    fi
}

# Set cv.spec.channel
function set_channel() {
    # with oc 4.9 and above, oc adm upgrade channel <channel> works for channel change
    # with oc 4.8 and below, oc patch clusterversion version --type json -p '[{"op": "add", "path": "/spec/channel", "value": "<channel>"}]' works for channel change
    if [[ $# -ne 1 ]]; then
        echo -e "Error on the number of the positional parameters, expected 1, but got $#\n" && return 0
    fi
    local oc_version oc_x_version oc_y_version cmd
    oc_version="$(oc version | grep -i client | sed 's/.*: //')"
    oc_x_version="$(echo "${oc_version}" | cut -f1 -d.)"
    oc_y_version="$(echo "${oc_version}" | cut -f2 -d.)"
    cmd="oc adm upgrade channel ${1}"
    if (( oc_x_version == 4 && oc_y_version < 9 )); then
        cmd="oc patch clusterversion version --type json -p '[{\"op\": \"add\", \"path\": \"/spec/channel\", \"value\": \"${1}\"}]'"
    fi
    if ! eval "${cmd}"; then
        echo >&2 "Changing upgrade channel failed"  && return 0
    else
        echo "Upgrade channel is changed" && return 0
    fi
}

# Upgrade the cluster to target release
function upgrade() {
    # At current stage, keep using production cincinnati and change the channel to candidate 
    echo "Switching upgrade channel"
    local channel="candidate-${target_major_minor_version}"
    set_channel "${channel}"
    
    echo "Get available updates"
    if avail_updates=$(oc get clusterversion/version -ojson | jq -r .status.availableUpdates[].version) && [[ -n "${avail_updates}" ]]; then
        if [[ ${avail_updates} == *"${target_version}"* ]]; then
            echo "${target_version} is one of recommended updates, upgrade cluster using oc adm upgrade --to"
            oc adm upgrade --to "${target_version}" "${force}"
        fi
    fi

    echo "Get conditional updates"
    if cond_updates=$(oc get clusterversion/version -ojson | jq -r .status.conditionalUpdates[].version) && [[ -n "${cond_updates}" ]]; then
        if [[ ${cond_updates} == *"${target_version}"* ]]; then
            echo "${target_version} is one of conditional updates, upgrade cluster using oc adm upgrade --to --allow-not-recommended"
            oc adm upgrade --to "${target_version}" --allow-not-recommended "${force}"
        fi
    fi 
    
    echo "Upgrade cluster using oc adm upgrade --to-image"
    oc adm upgrade --to-image="${target}" --allow-explicit-upgrade "${force}"
}

# Monitor the upgrade status
function check_upgrade_status() {
    local wait_upgrade="${TIMEOUT}" out avail progress
    while (( wait_upgrade > 0 )); do
        echo "oc get clusterversion" && oc get clusterversion
        out="$(oc get clusterversion --no-headers)"
        avail="$(echo "${out}" | awk '{print $3}')"
        progress="$(echo "${out}" | awk '{print $4}')"
        if [[ ${avail} == "True" && ${progress} == "False" && ${out} == *"Cluster version is ${target_version}" ]]; then
            echo -e "Upgrade succeed\n\n"
            return 0
        else
            sleep 5m
            (( wait_upgrade -= 5 ))
        fi        
    done
    if (( wait_upgrade <= 0 )); then
        echo "oc get clusterversion/version -oyaml" && oc get clusterversion/version -oyaml
        echo >&2 "Upgrade timeout, exiting" && return 1
    fi
}

# Check version, state in history
function check_history() {
    local cv version state
    cv=$(oc get clusterversion/version -o json)
    version=$(echo "${cv}" | jq -r '.status.history[0].version')
    state=$(echo "${cv}" | jq -r '.status.history[0].state')
    if [[ ${version} == "${target_version}" && ${state} == "Completed" ]]; then
        echo "History check PASSED, cluster is now upgraded to ${target_version}" && return 0
    else
        echo >&2 "History check FAILED, cluster upgrade to ${target_version} failed, current version is ${version}, exiting" && return 1
    fi
}

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "RELEASE_IMAGE_LATEST is ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_TARGET is ${RELEASE_IMAGE_TARGET}"

echo -e "Current cluster version: oc get clusterversion\n"
oc get clusterversion

echo -e "RELEASE_IMAGE_LATEST release info:\n"
oc adm release info "${RELEASE_IMAGE_LATEST}"

echo -e "RELEASE_IMAGE_TARGET release info:\n"
oc adm release info "${RELEASE_IMAGE_TARGET}"

target="${RELEASE_IMAGE_TARGET}"

source_minor_version="$(oc get clusterversion --no-headers | awk '{print $2}' | cut -f2 -d.)"
echo -e "Source release minor version is: ${source_minor_version}"

target_version="$(oc adm release info "${target}" --output=json | jq -r '.metadata.version')"
target_minor_version="$(echo "${target_version}" | cut -f2 -d.)"
target_major_minor_version="$(echo "${target_version}" | cut -f1,2 -d.)"
echo -e "Target release version is: ${target_version}\nTarget minor version is: ${target_minor_version}"

force=""
if ! check_signed; then
    echo "You're updating to an unsigned images, you must override the verification using --force flag"
    force="--force"
else
    admin_ack
fi

upgrade 
check_upgrade_status 
check_history 
