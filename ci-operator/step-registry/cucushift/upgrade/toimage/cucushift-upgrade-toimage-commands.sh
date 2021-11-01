#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Extract oc binary which is supposed to be identical with target release
function extract_oc(){
    set -x
    echo "Extracting oc: ${target}"
    if ! oc adm release extract --command='oc' "${target}" && chmod +x ./oc; then
        echo >&2 "Failed to extract oc binary, exiting" && exit 1
    fi
    set +x
}

# Get the target upgrades release, by default, RELEASE_IMAGE_LATEST is the target release
# If it's serial upgrades then override-upgrade file will store the release and overrides RELEASE_IMAGE_LATEST
# override-upgrade file expects a comma separated releases list like target_release1,target_release2,...
function get_target_release() {
    echo "RELEASE_IMAGE_INITIAL is ${RELEASE_IMAGE_INITIAL}"
    echo "RELEASE_IMAGE_LATEST is ${RELEASE_IMAGE_LATEST}"
    TARGET_RELEASES=("${RELEASE_IMAGE_LATEST}") &&
    if [[ -f "${SHARED_DIR}/override-upgrade" ]]; then
        local release_string; release_string="$(< "${SHARED_DIR}/override-upgrade")"
        # shellcheck disable=SC2207
        TARGET_RELEASES=($(echo "$release_string" | tr ',' ' ')) 
        echo "Overriding upgrade target to ${TARGET_RELEASES[*]}"
    fi
}

# Check if a release image signed
function validate_signed_image() {
    digest="$(echo "${target}" | cut -f2 -d@)"
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash="$(echo "${digest}" | cut -f2 -d:)"
    local response; response=$(curl --silent --output /dev/null --write-out "%{http_code}" "https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash}/signature-1")
    if [[ "$response" == "200" ]]; then
        echo "True"
    else
        echo "False"
    fi
}

# Check if admin ack is required before upgrade
function admin_ack() {
    set -x
    if [[ "${source_minor_version}" -eq "${target_minor_version}" ]]; then
        echo "Upgrade between z-stream version does not require admin ack"
    else
        local out; out="$(./oc -n openshift-config-managed get configmap admin-gates -o json | jq -r ".data")"
        if [[ $out == *"ack-4.${source_minor_version}"* ]]; then
            echo "Require admin ack"
            local ack_data; ack_data="$(echo "$out" | cut -f2 -d\")" && echo "Admin ack patch data is: ${ack_data}"
            if ! ./oc -n openshift-config patch configmap admin-acks --patch '{"data":{"'"${ack_data}"'": "true"}}' --type=merge; then
                echo >&2 "Admin-acks patch command failed, exiting" && exit 1
            fi
            
            echo -e "sleep 5 min wait admin-acks patch to be valid...\n"
            local wait_time_loop_var=0
            while(( wait_time_loop_var < 5 ));do
                sleep 1m
                echo -e "wait_time_passed=${wait_time_loop_var} min.\n"
                if ! ./oc adm upgrade|grep "AdminAckRequired"; then
                    echo -e "Admin-acks patch still in processing, waiting...\n"
                else
                    echo -e "Admin-acks patch finished succ\n"
                    break
                fi
                ((wait_time_loop_var+=1))
            done
            [ "${wait_time_loop_var}" -eq 5 ] && echo >&2 "Admin-acks patch not completed in 5 minutes, exiting" && exit 1
        fi
    fi
    set +x
}

# Upgrade the cluster to target release
# Parameters: 1- by-digest pull spec, 2- by-tag pull spec
function upgrade() {
    set -x
    local err
    
    if ! err="$(./oc adm upgrade --to-image="${target}" 2>&1 >/dev/null)" && [[ $err == *"you must pass --allow-explicit-upgrade to continue"* ]]; then
        echo "Check on oc adm upgrade --to-image missing --allow-explicit-upgrade PASSED"
    else
        echo >&2 "Check on oc adm upgrade --to-image missing --allow-explicit-upgrade FAILED: $err, exiting" && exit 1
    fi
    local current_image; current_image="$(./oc get clusterversion version -o json|jq -r '.status.history[0].image')"
    [[ ${target} == "${current_image}" ]] && echo >&2 "Upgrade with oc adm upgrade --to-image missing --allow-explicit-upgrade starts but expected NOT start, exiting" && exit 1
    
    if [[ "${FORCE_UPDATE}" == "false" ]]; then
        echo "Upgrading cluster to ${target}..."
        if ! ./oc adm upgrade --to-image="${target}" --allow-explicit-upgrade; then
            echo >&2 "Failed to start upgrade, exiting" && exit 1
        fi
    else
        echo "Force upgrading cluster to ${target_registry}:${target_tag}..."
        if ! ./oc adm upgrade --to-image="${target_registry}:${target_tag}" --allow-explicit-upgrade --force; then
            echo >&2 "Failed to start upgrade, exiting" && exit 1
        fi
    fi

    set +x
}

# Monitor the upgrade status
function check_upgrade_status() {
    local timeout=120
    local out="", avail="", progress=""
    while [ ${timeout} -gt 0 ]; do
        echo "./oc get clusterversion" && ./oc get clusterversion
        out="$(./oc get clusterversion --no-headers)"
        avail="$(echo "${out}" | awk '{print $3}')"
        progress="$(echo "${out}" | awk '{print $4}')"
        if [[ "${avail}" == "True" && "${progress}" == "False" && "${out}" == *"Cluster version is ${target_version}" ]]; then
            echo -e "Upgrade succ\n\n"
            break
        else
            sleep 5m
            ((timeout-=5))
        fi        
    done
    # Collect co, node, mcp, cv state for further debug
    echo "./oc get co" && ./oc get co
    echo "./oc get node" && ./oc get node
    echo "./oc get mcp" && ./oc get mcp
    echo "./oc get clusterversion version -oyaml" && ./oc get clusterversion version -oyaml
    [ "${timeout}" -le 0 ] && echo >&2 "Upgrade timeout, exiting" && exit 1

}

# Check version, state, verified in history
function check_history() {
    local history; history=$(./oc get clusterversion/version -o json)
    local version; version=$(echo "${history}" | jq -r '.status.history[0].version')
    local state; state=$(echo "${history}" | jq -r '.status.history[0].state')
    local verified; verified=$(echo "${history}" | jq -r '.status.history[0].verified')
    if [[ "${version}" == "${target_version}" && "${state}" == "Completed" ]]; then
        echo "History check PASSED, cluster is now upgraded to ${target_version}"
    else
        echo >&2 "History check FAILED, cluster upgrade to ${target_version} failed, current version is ${version}, exiting" && exit 1
    fi
    if [[ "${FORCE_UPDATE}" == "false" ]]; then
        if [[ "${signed}" == "True" && "${verified}" == "true" || "${signed}" == "False" && "${verified}" == "false" ]]; then
            echo "Verified state check PASSED"
        else
            echo >&2 "Verified state check FAILED, exiting" && exit 1
        fi
    else
        if [[ "${verified}" == "false" ]]; then
            echo "Verified state check PASSED"
        else
            echo >&2 "Verified state check FAILED, exiting" && exit 1
        fi
    fi
}

# Setup proxy if it's present in the shared dir
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Note: RELEASE_IMAGE_xxx is by-digest pull spec
# oc registry login creates registry credentials and then the oc adm release info command works 
oc registry login

get_target_release
for target in "${TARGET_RELEASES[@]}"
do       
    source_major_version="$(oc get clusterversion --no-headers | awk '{print $2}' | cut -f1 -d.)"
    source_minor_version="$(oc get clusterversion --no-headers | awk '{print $2}' | cut -f2 -d.)"
    echo -e "Source release major version is: ${source_major_version}\nSource release minor version is: ${source_minor_version}"
       
    target_registry="$(echo "${target}" | cut -f1 -d@)"
    target_version="$(oc adm release info "${target}" --output=json | jq -r '.metadata.version')"
    target_major_version="$(echo "${target_version}" | cut -f1 -d.)"
    target_minor_version="$(echo "${target_version}" | cut -f2 -d.)"
    target_tag="${target_version}"
    [[ ${target_version} != *"nightly"* ]] && target_tag="${target_version}-x86_64"
    echo -e "Target release is: ${target}\nTarget release version is: ${target_version}\nTarget release registry is: ${target_registry}\nTarget major version is: ${target_major_version}\nTarget minor version is: ${target_major_version}\nTarget tag is: ${target_tag}"
    
    extract_oc 

    signed=$(validate_signed_image)

    if [[ "${FORCE_UPDATE}" == "false" ]]; then
        admin_ack 
    fi
    
    upgrade 
    check_upgrade_status 
    check_history 
done
