#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; createUpgradeJunit; debug' EXIT TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        if [[ -n "${TARGET_MINOR_VERSION}" ]] && [[ "${TARGET_MINOR_VERSION}" -ge "16" ]] ; then
            echo -e "\n# oc adm upgrade status\n"
            env OC_ENABLE_CMD_UPGRADE_STATUS='true' oc adm upgrade status --details=all || true 
        fi
        echo -e "\n# oc get clusterversion/version -oyaml\n$(oc get clusterversion/version -oyaml)"
        echo -e "\n# oc get machineconfig\n$(oc get machineconfig)"
        echo -e "\n# Describing abnormal nodes...\n"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
        echo -e "\n# Describing abnormal operators...\n"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
        echo -e "\n# Describing abnormal mcp...\n"
        oc get machineconfigpools --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read mcp; do echo -e "\n#####oc describe mcp ${mcp}#####\n$(oc describe mcp ${mcp})"; done
    fi
}

# Explicitly set upgrade failure to operators
function check_failed_operator(){
    local latest_ver_in_history failing_status failing_operator failing_operators
    latest_ver_in_history=$(oc get clusterversion version -ojson|jq -r '.status.history[0].version')
    if [[ "${latest_ver_in_history}" != "${TARGET_VERSION}" ]]; then
        # Upgrade does not start, set it to CVO
        echo "Upgrade does not start, set UPGRADE_FAILURE_TYPE to cvo"
        export UPGRADE_FAILURE_TYPE="cvo"
    else
        failing_status=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").status')
        # Upgrade stuck at operators while failing=True, check from the operators reported in cv Failing condition
        if [[ ${failing_status} == "True" ]]; then
            failing_operator=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").message'|grep -oP 'operator \K.*?(?= is)') || true
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").message'|grep -oP 'operators \K.*?(?= are)'|tr -d ',') || true
            failing_operators="${failing_operator} ${failing_operators}"
        else
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'wait has exceeded 40 minutes for these operators: \K.*'|tr -d ',') || \
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'waiting up to 40 minutes on \K.*'|tr -d ',') || \
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'waiting on \K.*'|tr -d ',') || true
        fi
        if [[ -n "${failing_operators}" && "${failing_operators}" =~ [^[:space:]] ]]; then
            echo "Upgrade stuck, set UPGRADE_FAILURE_TYPE to ${failing_operators}"
            export UPGRADE_FAILURE_TYPE="${failing_operators}"
        fi
    fi
}

# Generate the Junit for upgrade
function createUpgradeJunit() {
    echo -e "\n# Generating the Junit for upgrade"
    local upg_report="${ARTIFACT_DIR}/junit_upgrade.xml"
    local cases_in_upgrade
    if (( FRC == 0 )); then
        # The cases are SLOs on the live cluster which may be a possible UPGRADE_FAILURE_TYPE
        local cases_from_available_operators upgrade_success_cases
        cases_from_available_operators=$(oc get co --no-headers|awk '{print $1}'|tr '\n' ' ' || true)
        upgrade_success_cases="${UPGRADE_FAILURE_TYPE} ${cases_from_available_operators} ${IMPLICIT_ENABLED_CASES}"
        upgrade_success_cases=$(echo ${upgrade_success_cases} | tr ' ' '\n'|sort -u|xargs)
        IFS=" " read -r -a cases_in_upgrade <<< "${upgrade_success_cases}"
        echo '<?xml version="1.0" encoding="UTF-8"?>' > "${upg_report}"
        echo "<testsuite name=\"cluster upgrade\" tests=\"${#cases_in_upgrade[@]}\" failures=\"0\">" >> "${upg_report}"
        for case in "${cases_in_upgrade[@]}"; do
            echo "  <testcase classname=\"cluster upgrade\" name=\"upgrade should succeed: ${case}\"/>" >> "${upg_report}"
        done
        echo '</testsuite>' >> "${upg_report}"
    else
        IFS=" " read -r -a cases_in_upgrade <<< "${UPGRADE_FAILURE_TYPE}"
        echo '<?xml version="1.0" encoding="UTF-8"?>' > "${upg_report}"
        echo "<testsuite name=\"cluster upgrade\" tests=\"${#cases_in_upgrade[@]}\" failures=\"${#cases_in_upgrade[@]}\">" >> "${upg_report}"
        for case in "${cases_in_upgrade[@]}"; do
            echo "  <testcase classname=\"cluster upgrade\" name=\"upgrade should succeed: ${case}\">" >> "${upg_report}"
            echo "    <failure message=\"openshift cluster upgrade failed at ${case}\"></failure>" >> "${upg_report}"
            echo "  </testcase>" >> "${upg_report}"
        done
        echo '</testsuite>' >> "${upg_report}"
    fi
}

# Add cloudcredential.openshift.io/upgradeable-to: <version_number> to cloudcredential cluster when cco mode is manual or the case in OCPQE-19413
function cco_annotation(){
    local source_version="${1}" target_version="${2}" source_minor_version target_minor_version
    source_minor_version="$(echo "$source_version" | cut -f2 -d.)"
    target_minor_version="$(echo "$target_version" | cut -f2 -d.)"
    if (( source_minor_version == target_minor_version )) || (( source_minor_version < 8 )); then
        echo "CCO annotation change is not required in either z-stream upgrade or 4.7 and earlier" && return
    fi

    local cco_mode; cco_mode="$(oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}')"
    local platform; platform="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')"
    if [[ ${cco_mode} == "Manual" ]]; then
        echo "CCO annotation change is required in Manual mode"
    elif [[ -z "${cco_mode}" || ${cco_mode} == "Mint" ]]; then
        if [[ "${source_minor_version}" == "14" && ${platform} == "GCP" ]] ; then
            echo "CCO annotation change is required in default or Mint mode on 4.14 GCP cluster"
        else
            echo "CCO annotation change is not required in default or Mint mode on 4.${source_minor_version} ${platform} cluster"
            return 0
        fi
    else
        echo "CCO annotation change is not required in ${cco_mode} mode"
        return 0
    fi

    echo "Require CCO annotation change"
    local wait_time_loop_var=0; to_version="$(echo "${target_version}" | cut -f1 -d-)"
    oc patch cloudcredential.operator.openshift.io/cluster --patch '{"metadata":{"annotations": {"cloudcredential.openshift.io/upgradeable-to": "'"${to_version}"'"}}}' --type=merge

    echo "CCO annotation patch gets started"

    echo -e "sleep 5 min wait CCO annotation patch to be valid...\n"
    while (( wait_time_loop_var < 5 )); do
        sleep 1m
        echo -e "wait_time_passed=${wait_time_loop_var} min.\n"
        if ! oc adm upgrade | grep "MissingUpgradeableAnnotation"; then
            echo -e "CCO annotation patch PASSED\n"
            return 0
        else
            echo -e "CCO annotation patch still in processing, waiting...\n"
        fi
        (( wait_time_loop_var += 1 ))
    done
    if (( wait_time_loop_var >= 5 )); then
        echo >&2 "Timed out waiting for CCO annotation completing, exiting"
        # Explicitly set failure to cco
        export UPGRADE_FAILURE_TYPE="cloud-credential"
        return 1
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# Check if admin ack is required before upgrade
function admin_ack() {
    local source_version="${1}" target_version="${2}" source_minor_version target_minor_version
    source_minor_version="$(echo "$source_version" | cut -f2 -d.)"
    target_minor_version="$(echo "$target_version" | cut -f2 -d.)"

    if (( source_minor_version == target_minor_version )) || (( source_minor_version < 8 )); then
        echo "Admin ack is not required in either z-stream upgrade or 4.7 and earlier" && return
    fi

    local out; out="$(oc -n openshift-config-managed get configmap admin-gates -o json | jq -r ".data")"
    echo -e "All admin acks:\n${out}"
    if [[ ${out} != *"ack-4.${source_minor_version}"* ]]; then
        echo "Admin ack not required: ${out}" && return
    fi

    echo -e "Require admin ack:\n ${out}"
    local wait_time_loop_var=0 ack_data

    ack_data="$(echo "${out}" | jq -r "keys[]")"
    for ack in ${ack_data};
    do
        # e.g.: ack-4.12-kube-1.26-api-removals-in-4.13
        if [[ "${ack}" == *"ack-4.${source_minor_version}"* ]]
        then
            echo "Admin ack patch data is: ${ack}"
            oc -n openshift-config patch configmap admin-acks --patch '{"data":{"'"${ack}"'": "true"}}' --type=merge
        fi
    done
    echo "Admin-acks patch gets started"

    echo -e "sleep 5 mins wait admin-acks patch to be valid...\n"
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
        echo >&2 "Timed out waiting for admin-acks completing, exiting"
        # Explicitly set failure to admin_ack
        export UPGRADE_FAILURE_TYPE="admin_ack"
        return 1
    fi
}

# Check if a build is signed
function check_signed() {
    local digest algorithm hash_value response try max_retries payload="${1}"
    if [[ "${payload}" =~ "@sha256:" ]]; then
        digest="$(echo "${payload}" | cut -f2 -d@)"
        echo "The target image is using digest pullspec, its digest is ${digest}"
    else
        digest="$(oc image info "${payload}" -o json | jq -r ".digest")"
        echo "The target image is using tagname pullspec, its digest is ${digest}"
    fi
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    try=0
    max_retries=3
    response=0
    while (( try < max_retries && response != 200 )); do
        echo "Trying #${try}"
        response=$(https_proxy="" HTTPS_PROXY="" curl -L --silent --output /dev/null --write-out %"{http_code}" "https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
        (( try += 1 ))
        sleep 60
    done
    if (( response == 200 )); then
        echo "${payload} is signed" && return 0
    else
        echo "Seem like ${payload} is not signed" && return 1
    fi
}

function clear_upgrade() {
    local cmd tmp_log expected_msg
    tmp_log=$(mktemp)
    cmd="oc adm upgrade --clear"
    expected_msg="Cancelled requested upgrade to"
    run_command "${cmd} 2>&1 | tee ${tmp_log}"
    if grep -q "${expected_msg}" "${tmp_log}"; then
        echo "Last upgrade is cleaned."
    else
        echo "Clear the last upgrade fail!"
        return 1
    fi
}

# Get multi pull spec for ***next minor version***, return 1 if failed to get to digest.
# $ get_multi_pullspec 4.20.1
function get_multi_pullspec() {
    local major_version minor_version version="${1}"
    major_version="$(echo "$version" | cut -f1 -d.)"
    minor_version="$(echo "$version" | cut -f2 -d.)"
    minor_version=$((minor_version + 1))

    echo "Will get pullspec for ${major_version}.${minor_version}.0-ec.0-multi" >&2
    
    digest=$(oc image info --show-multiarch quay.io/openshift-release-dev/ocp-release:"${major_version}"."${minor_version}".0-ec.0-multi -o json | jq -r ".[0].listDigest")
    if [[ -n "$digest" ]]; then
        echo "quay.io/openshift-release-dev/ocp-release@${digest}"
        return 0
    else
        echo "Error: unable to get digest"
        return 1
    fi
}

# Wait upgrade to start, https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-25473
# Following conditions will be used to determine if an upgrade is started
#   Progressing=True
#   ReleaseAccepted=True
#   Upgradeable=False (for ocp 4.19 and later)
# If not all above conditions check passed, we print a message and returns 1
function wait_upgrade_starts(){
    local retry=0 output
    echo "Wait for the upgrade to start"
    while [[ retry -lt 10 ]]; do
        output="$(oc get clusterversion version -ojson)"
        if [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "Progressing").status')" == "True" ]] \
            && [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "ReleaseAccepted").status')" == "True" ]]; then
            
            if [[ "$TARGET_MINOR_VERSION" -gt 18 ]]; then
                if [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "Upgradeable").status')" != "False" ]]; then
                    echo "The upgrade has not started yet, retry ${retry}"
                    retry=$(( retry+1 ))
                    sleep 1m
                    continue
                fi
            fi
            
            echo "Upgrade is processing"
            return 0
        fi
        echo "The upgrade has not started yet, retry ${retry}"
        retry=$(( retry+1 ))
        sleep 1m
    done
    echo "Error: upgrade not started, break the job"
    run_command "oc adm upgrade"
    return 1
}

# Upgrade the cluster to target release
function upgrade() {
    # As https://issues.redhat.com/browse/OTA-861 required, we can re-target to a z version when an upgrade is processing.
    # For example, there is one upgrade is in progress A -> B (no matter it is a y stream or a z stream upgrade)
    # Then:
    # 1. we can retarget to a version which has same minor version with B
    # 2. we can NOT retarget to a version which minor version is great than B
    # *******************
    # Nightly build is not applicable for z stream retarget tests
    # *******************
    # No matter y stream or z stream retarget, the TARGET always the final version we want to upgrade to
    # To make OCP-25473 not block the whole pipeline, the upgrade orders are:
    #  if the minor version in ${SHARED_DIR}/upgrade-edge is greater than target, then
    #       initial -> target -> ${SHARED_DIR}/upgrade-edge
    #  if ${SHARED_DIR}/upgrade-edge is empty, then
    #       1. get a new target version which greater than target
    #       2. initial -> target -> new target
    #  if the minor version in ${SHARED_DIR}/upgrade-edge equal to target, then
    #       1. we find a target+1 version as third target upgrade version
    #       2. initial -> ${SHARED_DIR}/upgrade-edge -> target -> third target version
    #  this case not allow ${SHARED_DIR}/upgrade-edge less than target

    # INTERMEDIATE_MINOR_VERSION is the minor version in ${SHARED_DIR}/upgrade-edge
    local retry=0 intermediate_image INTERMEDIATE_MINOR_VERSION FIRST_MINOR_VERSION SECOND_MINOR_VERSION block_second first_upgrade_to_image second_upgrade_to_image third_upgrade_to_image output latest_minor_version
    local testcase="OCP-25473"
    export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${testcase}"
    
    echo "Prepare test data"
    
    if ! [ -e "${SHARED_DIR}/upgrade-edge" ]; then
        # This is y stream retarget upgrade, e.g.: 4.y -> (4.y | 4.y+1) -> (4.y+1 | 4.y+2)
        echo "upgrade-edge is empty, get a new target"
        first_upgrade_to_image=${TARGET}
        if ! second_upgrade_to_image=$(get_multi_pullspec "${TARGET_VERSION}"); then
            echo "Error: OCP-25473 could not get new target pullsepc"
            return 1
        fi
        echo "New target pullspec is: ${second_upgrade_to_image}"
        block_second=true
    else
        intermediate_image="$(< "${SHARED_DIR}/upgrade-edge")"
        echo "upgrade-edge exists, the pullspec is: ${intermediate_image}"
        INTERMEDIATE_MINOR_VERSION="$(oc adm release info -ojson "$intermediate_image" | jq -r '.metadata.version' | cut -f2 -d.)"
        if [[ "$INTERMEDIATE_MINOR_VERSION" -gt "$TARGET_MINOR_VERSION" ]]; then
            # This is y stream retarget upgrade, e.g.: 4.y -> (4.y | 4.y+1) -> (4.y+1 | 4.y+2)
            first_upgrade_to_image=${TARGET}
            second_upgrade_to_image=${intermediate_image}
            block_second=true
        else
            if [[ "$INTERMEDIATE_MINOR_VERSION" == "$TARGET_MINOR_VERSION" ]]; then
                # This is z stream retarget upgrade, e.g.: 4.y -> (4.y | 4.y+1) -> (4.y | 4.y+1)
                first_upgrade_to_image=${intermediate_image}
                second_upgrade_to_image=${TARGET}
                
                if oc adm release info -o jsonpath='{.digest}' quay.io/openshift-release-dev/ocp-release:4.$((TARGET_MINOR_VERSION+1)).0-ec.0-x86_64 2>&1; then
                    # if third_upgrade_to_image not empty, we will retarget to it, but it will always be blocked
                    # this can make sure we always have z and y stream retarget in one job
                    latest_minor_version=$(( TARGET_MINOR_VERSION+1 ))
                    third_upgrade_to_image="$( oc adm release info -o jsonpath='{.digest}' quay.io/openshift-release-dev/ocp-release:4.${latest_minor_version}.0-ec.0-x86_64 )"
                    third_upgrade_to_image="quay.io/openshift-release-dev/ocp-release@${third_upgrade_to_image}"
                fi

                block_second=false
            else
                # If INTERMEDIATE_MINOR_VERSION < TARGET_MINOR_VERSION, then we will naver be able to upgrade to TARGET_MINOR_VERSION
                # So do not put a small version in upgrade-edge
                echo "Error: OCP-25473 do not cover rollback, break the job"
                return 1
            fi
        fi
    fi

    local first_version second_version
    first_version="$(oc adm release info -ojson "$first_upgrade_to_image" | jq -r '.metadata.version')"
    FIRST_MINOR_VERSION="$(echo "$first_version" | cut -f2 -d.)"
    second_version="$(oc adm release info -ojson "$second_upgrade_to_image" | jq -r '.metadata.version')"
    SECOND_MINOR_VERSION="$(echo "$second_version" | cut -f2 -d.)"

    # first_upgrade_to_image can be both nightly build or stable build
    if ! check_signed "${first_upgrade_to_image}"; then
        FORCE_UPDATE="true"
    else
        FORCE_UPDATE="false"
        # if the first upgade is y stream upgrade and upgrade to a stable version,
        # we run cco_annotation and admin_ack
        if [[ "$FIRST_MINOR_VERSION" -gt "$SOURCE_MINOR_VERSION" ]]; then
            cco_annotation "${SOURCE_VERSION}" "${first_version}"
            admin_ack "${SOURCE_VERSION}" "${first_version}"
        fi
    fi
    run_command "oc adm upgrade --to-image=${first_upgrade_to_image} --allow-explicit-upgrade --force=${FORCE_UPDATE}"
    wait_upgrade_starts

    echo "OCP-25473: Upgrade to new target without --allow-upgrade-with-warnings"
    # second_upgrade_to_image must be ***stable*** build
    output="$(oc adm upgrade --to-image="${second_upgrade_to_image}" --allow-explicit-upgrade 2>&1 || true)"
    if [[ ! "${output}" =~ "error: the cluster is already upgrading" ]] || [[ ! "${output}" =~ "If you want to upgrade anyway, use --allow-upgrade-with-warnings" ]]; then
        echo "Error: OCP-25473: Re-upgrade should not started and raise error when there is already an upgrade is processing"
        echo "The output of 'oc adm upgrade' is:"
        echo "$output"
        return 1
    fi
    
    echo "OCP-25473: Upgrade to new target again with --allow-upgrade-with-warnings"
    # if second version is greater than the first version we run cco_annotation (second version always stable version for OCP-25473)
    # because the first upgrade has not finished, so we don't need to run admin_ack
    if [[ "$SECOND_MINOR_VERSION" -gt "$FIRST_MINOR_VERSION" ]]; then
        cco_annotation "${first_version}" "${second_version}"
    fi
    run_command "oc adm upgrade --to-image=${second_upgrade_to_image} --allow-explicit-upgrade --allow-upgrade-with-warnings=true"
    sleep 1m
    if $block_second; then
        echo "This is re-targeting to a y version, this upgrade should be blocked"
        output="$(oc get clusterversion version -ojson)"
        if [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "Progressing").status')" != "True" ]] \
            || [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "Upgradeable").status')" != "False" ]] \
            || [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "ReleaseAccepted").status')" != "False" ]] \
            || ! [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "ReleaseAccepted").message')" =~ ${second_upgrade_to_image} ]]; then
            echo "Error: OCP-25473: Retarget to a y stream version should be blocked, but actually not"
            return 1
        fi
        run_command "oc adm upgrade --clear"
        sleep 1m
        output="$(oc get clusterversion version -ojson)"
        if [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "Progressing").status')" != "True" ]] \
            || [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "Upgradeable").status')" != "False" ]] \
            || [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "ReleaseAccepted").status')" != "True" ]]; then
            echo "Error: OCP-25473: After clearing the upgrade, Progressing/Upgradeable/ReleaseAccepted not all correct"
            return 1
        fi

        # for OCPBUGS-42880
        oc -n openshift-config-managed patch configmap admin-gates \
            --type json \
            -p '[{"op": "add", "path": "/data", "value": {"ack-4.'"${SOURCE_MINOR_VERSION}"'-testing": "gate-testing"}}]'
        sleep 1m
        output="$(oc adm upgrade)"
        if ! [[ "$output" =~ "gate-testing" ]] \
            || ! [[ "$output" =~ "Upgradeable=False" ]]; then
            echo "Error: OCP-25473: After patch admin-gates, the message is not correct, the observed output is:"
            echo "$output"
            return 1
        fi
    else
        echo "This is re-targeting to a z version, upgrade should switch to new target"
        retry=0
        while [[ retry -lt 5 ]]; do
            output="$(oc get clusterversion version -ojson)"
            if [[ "$(echo "$output" | jq -r '.status.desired.image')" == "${second_upgrade_to_image}" ]] \
                && [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "ReleaseAccepted").status')" == "True" ]]; then
                echo "OCP-25473: Upgrade to new version"
                return 0
            fi
            retry=$(( retry+1 ))
            sleep 1m
        done
        echo "Error: OCP-25473: Retarget to a z stream version should be success, but actually not, break the job"
        return 1
    fi

    if [[ -n ${third_upgrade_to_image:-} ]]; then
        run_command "oc adm upgrade --to-image=${third_upgrade_to_image} --allow-explicit-upgrade --allow-upgrade-with-warnings=true"
        echo "This is re-targeting to a y version after a z version retarget, this upgrade should be blocked"
        output="$(oc get clusterversion version -ojson)"
        if [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "Progressing").status')" != "True" ]] \
            || [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "Upgradeable").status')" != "False" ]] \
            || [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "ReleaseAccepted").status')" != "False" ]] \
            || ! [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "ReleaseAccepted").message')" =~ ${third_upgrade_to_image} ]]; then
            echo "Error: OCP-25473: Retarget to a y stream version should be blocked, but actually not"
            return 1
        fi
        run_command "oc adm upgrade --clear"
        sleep 1m
    fi
    return
}

# Monitor the upgrade status
function check_upgrade_status() {
    local wait_upgrade="${TIMEOUT}" interval=1 out avail progress cluster_version stat_cmd stat='empty' oldstat='empty' filter='[0-9]+h|[0-9]+m|[0-9]+s|[0-9]+%|[0-9]+.[0-9]+s|[0-9]+ of|\s+|\n' start_time end_time
    cluster_version="${TARGET_VERSION}"
    echo -e "Upgrade checking start at $(date "+%F %T")\n"
    start_time=$(date "+%s")

    # https://issues.redhat.com//browse/OTA-861
    # When upgrade is processing, Upgradeable will be set to false
    sleep 120 # while waiting for condition to populate
    local case_id="OCP-25473"
    if [[ "$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].status}')" != "False" ]] \
      && [[ "$TARGET_MINOR_VERSION" -gt 18 ]]; then
        echo "Error: ${case_id} As OTA-861 designed, Upgradeable should be set to False when an upgrade is in progress, but actually not"
        export UPGRADE_FAILURE_TYPE="${case_id}"
        export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${case_id}"
        return 1
    fi

    # print once to log (including full messages)
    oc adm upgrade || true
    # log oc adm upgrade (excluding garbage messages)
    stat_cmd="oc adm upgrade | grep -vE 'Upstream is unset|Upstream: https|available channels|No updates available|^$'"
    # if available (version 4.16+) log "upgrade status" instead
    if [[ -n "${TARGET_MINOR_VERSION}" ]] && [[ "${TARGET_MINOR_VERSION}" -ge "16" ]] ; then
        stat_cmd="env OC_ENABLE_CMD_UPGRADE_STATUS=true oc adm upgrade status 2>&1 | grep -vE 'no token is currently in use|for additional description and links'"
    fi
    while (( wait_upgrade > 0 )); do
        sleep ${interval}m
        wait_upgrade=$(( wait_upgrade - interval ))
        # if output is different from previous (ignoring irrelevant time/percentage difference), write to log
        if stat="$(eval "${stat_cmd}")" && [ -n "$stat" ] && ! diff -qw <(sed -zE "s/${filter}//g" <<< "${stat}") <(sed -zE "s/${filter}//g" <<< "${oldstat}") >/dev/null ; then
            echo -e "=== Upgrade Status $(date "+%T") ===\n${stat}\n\n\n\n"
            oldstat=${stat}
        fi
        if ! out="$(oc get clusterversion --no-headers || false)"; then
            echo "Error occurred when getting clusterversion"
            continue 
        fi
        avail="$(echo "${out}" | awk '{print $3}')"
        progress="$(echo "${out}" | awk '{print $4}')"
        if [[ ${avail} == "True" && ${progress} == "False" && ${out} == *"Cluster version is ${cluster_version}" ]]; then
            echo -e "Upgrade checking end at $(date "+%F %T") - succeed\n"
            end_time=$(date "+%s")
            echo -e "Eclipsed Time: $(( ($end_time - $start_time) / 60 ))m\n"
            return 0
        fi
    done
    if [[ ${wait_upgrade} -le 0 ]]; then
        echo -e "Upgrade checking timeout at $(date "+%F %T")\n"
        end_time=$(date "+%s")
        echo -e "Eclipsed Time: $(( ($end_time - $start_time) / 60 ))m\n"
        check_failed_operator
        return 1
    fi
}

# Check version, state in history
function check_history() {
    local version state
    version=$(oc get clusterversion/version -o jsonpath='{.status.history[0].version}')
    state=$(oc get clusterversion/version -o jsonpath='{.status.history[0].state}')
    if [[ ${version} == "${TARGET_VERSION}" && ${state} == "Completed" ]]; then
        echo "History check PASSED, cluster is now upgraded to ${TARGET_VERSION}" && return 0
    else
        echo >&2 "History check FAILED, cluster upgrade to ${TARGET_VERSION} failed, current version is ${version}, exiting"
	# Explicitly set failure to cvo
        export UPGRADE_FAILURE_TYPE="cvo"
	return 1
    fi
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

#support HyperShift upgrade
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# oc cli is injected from release:target
run_command "which oc"
run_command "oc version --client"
run_command "oc get machineconfigpools"
run_command "oc get machineconfig"

export TARGET_MINOR_VERSION=""
export TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"
TARGET_MINOR_VERSION="$(echo "${TARGET_VERSION}" | cut -f2 -d.)"
export TARGET_VERSION
echo -e "Target release version is: ${TARGET_VERSION}\nTarget minor version is: ${TARGET_MINOR_VERSION}"

SOURCE_VERSION="$(oc get clusterversion --no-headers | awk '{print $2}')"
SOURCE_MINOR_VERSION="$(echo "${SOURCE_VERSION}" | cut -f2 -d.)"
export SOURCE_VERSION
export SOURCE_MINOR_VERSION
echo -e "Source release version is: ${SOURCE_VERSION}\nSource minor version is: ${SOURCE_MINOR_VERSION}"

export FORCE_UPDATE="false"
# Set genenral upgrade ci failure to overall as default
export UPGRADE_FAILURE_TYPE="OCP-25473"
# The cases are from the general checkpoints setting explicitly in upgrade step by export UPGRADE_FAILURE_TYPE="xxx".
export IMPLICIT_ENABLED_CASES=""

upgrade
check_upgrade_status
