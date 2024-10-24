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

# Generate the Junit for upgrade
function createUpgradeJunit() {
    echo -e "\n# Generating the Junit for upgrade"
    if (( FRC == 0 )); then
      cat >"${ARTIFACT_DIR}/junit_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster upgrade" tests="1" failures="0">
  <testcase classname="cluster upgrade" name="upgrade should succeed"/>
</testsuite>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster upgrade" tests="1" failures="1">
  <testcase classname="cluster upgrade" name="upgrade should succeed">
    <failure message="">openshift cluster upgrade failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

function extract_ccoctl(){
    local payload_image image_arch cco_image
    local retry=5
    local tmp_ccoctl="/tmp/upgtool"
    mkdir -p ${tmp_ccoctl}
    export PATH=/tmp:${PATH}

    echo -e "Extracting ccoctl\n"
    payload_image="${TARGET}"
    set -x
    image_arch=$(oc adm release info ${payload_image} -a "${CLUSTER_PROFILE_DIR}/pull-secret" -o jsonpath='{.config.architecture}')
    if [[ "${image_arch}" == "arm64" ]]; then
        echo "The target payload is arm64 arch, trying to find out a matched version of payload image on amd64"
        if [[ -n ${RELEASE_IMAGE_TARGET:-} ]]; then
            payload_image=${RELEASE_IMAGE_TARGET}
            echo "Getting target release image from RELEASE_IMAGE_TARGET: ${payload_image}"
        elif env "NO_PROXY=*" "no_proxy=*" "KUBECONFIG=" oc get istag "release:target" -n ${NAMESPACE} &>/dev/null; then
            payload_image=$(env "NO_PROXY=*" "no_proxy=*" "KUBECONFIG=" oc -n ${NAMESPACE} get istag "release:target" -o jsonpath='{.tag.from.name}')
            echo "Getting target release image from build farm imagestream: ${payload_image}"
        fi
    fi
    set +x
    cco_image=$(oc adm release info --image-for='cloud-credential-operator' ${payload_image} -a "${CLUSTER_PROFILE_DIR}/pull-secret") || return 1
    while ! (env "NO_PROXY=*" "no_proxy=*" oc image extract $cco_image --path="/usr/bin/ccoctl:${tmp_ccoctl}" -a "${CLUSTER_PROFILE_DIR}/pull-secret");
    do
        echo >&2 "Failed to extract ccoctl binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_ccoctl}/ccoctl /tmp -f
    if [[ ! -e /tmp/ccoctl ]]; then
        echo "No ccoctl tool found!" && return 1
    else
        chmod 775 /tmp/ccoctl
    fi
    export PATH="$PATH"
}

function update_cloud_credentials_oidc(){
    local platform preCredsDir tobeCredsDir tmp_ret

    platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')
    preCredsDir="/tmp/pre-include-creds"
    tobeCredsDir="/tmp/tobe-include-creds"
    mkdir "${preCredsDir}" "${tobeCredsDir}"
    # Extract all CRs from live cluster with --included
    if ! oc adm release extract --to "${preCredsDir}" --included --credentials-requests; then
        echo "Failed to extract CRs from live cluster!" && exit 1
    fi
    if ! oc adm release extract --to "${tobeCredsDir}" --included --credentials-requests "${TARGET}"; then
        echo "Failed to extract CRs from tobe upgrade release payload!" && exit 1
    fi

    # TODO: add gcp and azure
    # Update iam role with ccoctl based on tobeCredsDir
    tmp_ret=0
    diff -r "${preCredsDir}" "${tobeCredsDir}" || tmp_ret=1
    if [[ ${tmp_ret} != 0 ]]; then
        toManifests="/tmp/to-manifests"
        mkdir "${toManifests}"
        case "${platform}" in
        "AWS")
            if [[ ! -e ${SHARED_DIR}/aws_oidc_provider_arn ]]; then
                echo "No aws_oidc_provider_arn file in SHARED_DIR" && exit 1
            else
                export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
                infra_name=${NAMESPACE}-${UNIQUE_HASH}
                oidc_provider=$(head -n1 ${SHARED_DIR}/aws_oidc_provider_arn)
                extract_ccoctl
                if ! ccoctl aws create-iam-roles --name="${infra_name}" --region="${LEASED_RESOURCE}" --credentials-requests-dir="${tobeCredsDir}" --identity-provider-arn="${oidc_provider}" --output-dir="${toManifests}"; then
                    echo "Failed to update iam role!" && exit 1
                fi
                if [[ "$(ls -A ${toManifests}/manifests)" ]]; then
                    echo "Apply the new credential secrets."
                    oc apply -f "${toManifests}/manifests"
                fi
            fi
            ;;
        *)
           echo "to be supported platform: ${platform}" 
           ;;
        esac
    fi
}

# Add cloudcredential.openshift.io/upgradeable-to: <version_number> to cloudcredential cluster when cco mode is manual or the case in OCPQE-19413
function cco_annotation(){
    if (( SOURCE_MINOR_VERSION == TARGET_MINOR_VERSION )) || (( SOURCE_MINOR_VERSION < 8 )); then
        echo "CCO annotation change is not required in either z-stream upgrade or 4.7 and earlier" && return
    fi

    local cco_mode; cco_mode="$(oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}')"
    local platform; platform="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')"
    if [[ ${cco_mode} == "Manual" ]]; then
        echo "CCO annotation change is required in Manual mode"
    elif [[ -z "${cco_mode}" || ${cco_mode} == "Mint" ]]; then
        if [[ "${SOURCE_MINOR_VERSION}" == "14" && ${platform} == "GCP" ]] ; then
            echo "CCO annotation change is required in default or Mint mode on 4.14 GCP cluster"
        else
            echo "CCO annotation change is not required in default or Mint mode on 4.${SOURCE_MINOR_VERSION} ${platform} cluster"
            return 0
        fi
    else
        echo "CCO annotation change is not required in ${cco_mode} mode"
        return 0
    fi

    echo "Require CCO annotation change"
    local wait_time_loop_var=0; to_version="$(echo "${TARGET_VERSION}" | cut -f1 -d-)"
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
        echo >&2 "Timed out waiting for CCO annotation completing, exiting" && return 1
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# Check if a build is signed
function check_signed() {
    local digest algorithm hash_value response try max_retries
    if [[ "${TARGET}" =~ "@sha256:" ]]; then
        digest="$(echo "${TARGET}" | cut -f2 -d@)"
        echo "The target image is using digest pullspec, its digest is ${digest}"
    else
        digest="$(oc image info "${TARGET}" -o json | jq -r ".digest")"
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
        echo "${TARGET} is signed" && return 0
    else
        echo "Seem like ${TARGET} is not signed" && return 1
    fi
}

# Check if admin ack is required before upgrade
function admin_ack() {
    if (( SOURCE_MINOR_VERSION == TARGET_MINOR_VERSION )) || (( SOURCE_MINOR_VERSION < 8 )); then
        echo "Admin ack is not required in either z-stream upgrade or 4.7 and earlier" && return
    fi

    local out; out="$(oc -n openshift-config-managed get configmap admin-gates -o json | jq -r ".data")"
    echo -e "All admin acks:\n${out}"
    if [[ ${out} != *"ack-4.${SOURCE_MINOR_VERSION}"* ]]; then
        echo "Admin ack not required: ${out}" && return
    fi

    echo "Require admin ack:\n ${out}"
    local wait_time_loop_var=0 ack_data

    ack_data="$(echo "${out}" | jq -r "keys[]")"
    for ack in ${ack_data};
    do
        # e.g.: ack-4.12-kube-1.26-api-removals-in-4.13
        if [[ "${ack}" == *"ack-4.${SOURCE_MINOR_VERSION}"* ]]
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
        echo >&2 "Timed out waiting for admin-acks completing, exiting" && return 1
    fi
}

# Check if the cluster hit the image validation error, which caused by image signature
function error_check_invalid_image() {
    local try=0 max_retries=5 tmp_log cmd expected_msg
    tmp_log=$(mktemp)
    while (( try < max_retries )); do
        echo "Trying #${try}"
        cmd="oc adm upgrade"
        expected_msg="failure=The update cannot be verified:"
        run_command "${cmd} 2>&1 | tee ${tmp_log}"
        if grep -q "${expected_msg}" "${tmp_log}"; then
            echo "Found the expected validation error message"
            break
        fi
        (( try += 1 ))
        sleep 60
    done
    if (( ${try} >= ${max_retries} )); then
        echo >&2 "Timed out catching image invalid error message..." && return 1
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

# Wait upgrade to start, https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-25473
# Following conditions will be used to determine if an upgrade is started
#   Progressing=True
#   ReleaseAccepted=True
#   Upgradeable=False (for ocp 4.18 and later)
# If not all above conditions check passed, we print a message and returns 1
function wait_upgrade_start(){
    local retry=0 output
    echo "Wait for the upgrade to start"
    while [[ retry -lt 5 ]]; do
        output="$(oc get clusterversion version -ojson)"
        if [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "Progressing").status')" == "True" ]] \
            && [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "ReleaseAccepted").status')" == "True" ]]; then
            
            if [[ "$TARGET_MINOR_VERSION" -gt 17 ]]; then
                if [[ "$(echo "$output" | jq -r '.status.conditions[] | select(.type == "Upgradeable").status')" != "False" ]]; then
                    retry=$(( retry+1 ))
                    sleep 1m
                    continue
                fi
            fi
            
            echo "Upgrade is processing"
            return 0
        fi
        retry=$(( retry+1 ))
        sleep 1m
    done
    echo "Error: OCP-25473: upgrade not started, break the job"
    return 1
}

# Upgrade the cluster to target release
function upgrade() {
    local log_file history_len cluster_src_ver
    if check_ota_case_enabled "OCP-21588"; then
        log_file=$(mktemp)
        echo "Testing --allow-explicit-upgrade option"
        run_command "oc adm upgrade --to-image=${TARGET} --force=${FORCE_UPDATE} 2>&1 | tee ${log_file}" || true
        if grep -q 'specify --allow-explicit-upgrade to continue' "${log_file}"; then
            echo "--allow-explicit-upgrade prompt message is shown"
        else
            echo "--allow-explicit-upgrade prompt message is NOT shown!"
            exit 1
        fi
        history_len=$(oc get clusterversion -o json | jq '.items[0].status.history | length')
        if [[ "${history_len}" != 1 ]]; then
            echo "seem like there are more than 1 hisotry in CVO, sounds some unexpected update happened!"
            exit 1
        fi
    fi
    if check_ota_case_enabled "OCP-24663"; then
        cluster_src_ver=$(oc version -o json | jq -r '.openshiftVersion')
        if [[ -z "${cluster_src_ver}" ]]; then
            echo "Did not get cluster version at this moment"
            exit 1
        else
            echo "Current cluster is on ${cluster_src_ver}"
        fi
        echo "Negative Testing: upgrade to an unsigned image without --force option"
        admin_ack
        cco_annotation
        run_command "oc adm upgrade --to-image=${TARGET} --allow-explicit-upgrade"
        error_check_invalid_image
        clear_upgrade
        check_upgrade_status "${cluster_src_ver}"
    fi
    if check_ota_case_enabled "OCP-25473"; then
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
        #  if the minor version in ${SHARED_DIR}/upgrade-edge great than target, then
        #       initial -> target -> ${SHARED_DIR}/upgrade-edge
        #  if the minor version in ${SHARED_DIR}/upgrade-edge equal to target, then
        #       1. we find a target+1 version as third target upgrade version
        #       2. initial -> ${SHARED_DIR}/upgrade-edge -> target -> third target version
        #  this case not allow ${SHARED_DIR}/upgrade-edge less than target

        # INTERMEDIATE_MINOR_VERSIONT is the minor version in ${SHARED_DIR}/upgrade-edge
        local retry=0 intermediate_image INTERMEDIATE_MINOR_VERSIONT block_second first_upgrade_to_image second_upgrade_to_image third_upgrade_to_image output latest_minor_version
        intermediate_image="$(< "${SHARED_DIR}/upgrade-edge")"
        if [[ -z "${intermediate_image:-}" ]]; then
            echo "Error: The intermediate image is not given, break the job"
            return 1
        fi
        
        echo "Prepare test data"
        INTERMEDIATE_MINOR_VERSIONT="$(oc adm release info -ojson "$intermediate_image" | jq -r '.metadata.version' | cut -f2 -d.)"
        if [[ "$INTERMEDIATE_MINOR_VERSIONT" -gt "$TARGET_MINOR_VERSION" ]]; then
            # This is y stream retarget upgrade, e.g.: 4.y -> (4.y | 4.y+1) -> (4.y+1 | 4.y+2)
            first_upgrade_to_image=${TARGET}
            second_upgrade_to_image=${intermediate_image}
            block_second=true
        else
            if [[ "$INTERMEDIATE_MINOR_VERSIONT" == "$TARGET_MINOR_VERSION" ]]; then
                # This is z stream retarget upgrade, e.g.: 4.y -> (4.y | 4.y+1) -> (4.y | 4.y+1)
                first_upgrade_to_image=${intermediate_image}
                second_upgrade_to_image=${TARGET}
                
                if oc adm release info -o jsonpath='{.digest}' quay.io/openshift-release-dev/ocp-release:4.$((TARGET_MINOR_VERSION+1)).0-ec.0-x86_64 2>&1; then
                    # if third_upgrade_to_image not empty, we will retarget to it, but it will always be blocked
                    # this can make sure we always have z and y stream retarget in one job
                    latest_minor_version=$(( TARGET_MINOR_VERSION+1 ))
                    third_upgrade_to_image="$( oc adm release info -o jsonpath='{.digest}' quay.io/openshift-release-dev/ocp-release:4.${latest_minor_version}.0-ec.0-x86_64 )"
                fi

                block_second=false
            else
                # If INTERMEDIATE_MINOR_VERSIONT < TARGET_MINOR_VERSION, then we will naver be able to upgrade to TARGET_MINOR_VERSION
                # So do not put a small version in upgrade-edge
                echo "Error: OCP-25473 do not cover rollback, break the job"
                return 1
            fi
        fi
        # first_upgrade_to_image can be both nightly build or stable build
        run_command "oc adm upgrade --to-image=${first_upgrade_to_image} --allow-explicit-upgrade --force=${FORCE_UPDATE}"
        wait_upgrade_start

        echo "OCP-25473: Upgrade to new target without --allow-upgrade-with-warnings"
        # second_upgrade_to_image must be ***stable*** build
        output="$(oc adm upgrade --to-image="${second_upgrade_to_image}" --allow-explicit-upgrade 2>&1 || true)"
        if [[ ! "${output}" =~ "error: the cluster is already upgrading" ]] || [[ ! "${output}" =~ "If you want to upgrade anyway, use --allow-upgrade-with-warnings" ]]; then
            echo "Error: OCP-25473: Re-upgrade should not started and raise error when there is already an upgrade is processing"
            echo "The output of 'oc adm upgrade' is:"
            echo "$output"
            exit 1
        fi
        
        echo "OCP-25473: Upgrade to new target again with --allow-upgrade-with-warnings"
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
                -p '[{"op": "add", "path": "/data", "value": {"ack-4.'${SOURCE_MINOR_VERSION}'-testing": "gate-testing"}}]'
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
                output="$(oc get clusterversion version -oyaml)"
                if [[ "$(echo "$output" | yq -r '.status.desired.image')" == "${second_upgrade_to_image}" ]] \
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
    fi
    run_command "oc adm upgrade --to-image=${TARGET} --allow-explicit-upgrade --force=${FORCE_UPDATE}"
    echo "Upgrading cluster to ${TARGET} gets started..."
}

# https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-73352
function check_upgrade_recommend_when_upgrade_inprogress() {
    if [[ "${TARGET_MINOR_VERSION}" -eq "18" ]] || [[ "${TARGET_MINOR_VERSION}" -eq "19" ]] ; then
        # So far, this is a TP feature in OCP 4.18 and OCP 4.19, so need to enable the gate 
        export OC_ENABLE_CMD_UPGRADE_RECOMMEND=true
    fi
    
    local out 
    local info="info: An update is in progress.  You may wish to let this update complete before requesting a new update."
    local no_update="No updates available. You may still upgrade to a specific release image with --to-image or wait for new updates to be available."
    local error="error: no updates available, so cannot display context for the requested release 4.999.999"

    echo "OCP-73352: Checking \"oc adm upgrade recommend\" command"
    out="$(oc adm upgrade recommend)"
    if [[ "${out}" != *"${info}"* ]] || [[ "${out}" != *"${no_update}"* ]]; then
        echo "OCP-73352: Command \"oc adm upgrade recommend\" should output \"${info}\" and \"${no_update}\", but actualy not: \"${out}\""
        return 1
    fi
    out="$(oc adm upgrade recommend --show-outdated-releases)"
    if [[ "${out}" != *"${info}"* ]] || [[ "${out}" != *"${no_update}"* ]]; then
        echo "OCP-73352: Command \"oc adm upgrade recommend --show-outdated-releases\" should output \"${info}\" and \"${no_update}\", but actualy not: \"${out}\""
        return 1
    fi
    out="$(oc adm upgrade recommend --version 4.999.999 2>&1)"
    if [[ "${out}" != *"${info}"* ]] || [[ "${out}" != *"${error}"* ]]; then
        echo "OCP-73352: Command \"oc adm upgrade recommend --version 4.999.999\" should output \"${info}\" and \"${error}\", but actualy not: \"${out}\""
        return 1
    fi
    echo "OCP-73352: \"oc adm upgrade recommend\" command works normal"
    return 0
}

# Monitor the upgrade status
function check_upgrade_status() {
    local wait_upgrade="${TIMEOUT}" interval=1 out avail progress cluster_version stat_cmd stat='empty' oldstat='empty' filter='[0-9]+h|[0-9]+m|[0-9]+s|[0-9]+%|[0-9]+.[0-9]+s|[0-9]+ of|\s+|\n' start_time end_time
    if [[ -n "${1:-}" ]]; then
        cluster_version="$1"
    else
        cluster_version="${TARGET_VERSION}"
    fi
    echo -e "Upgrade checking start at $(date "+%F %T")\n"
    start_time=$(date "+%s")

    # https://issues.redhat.com//browse/OTA-861
    # When upgrade is processing, Upgradeable will be set to false
    sleep 5 # while waiting for condition to populate
    if [[ "$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].status}')" != "False" ]]; then
        echo "Error: As OTA-861 designed, Upgradeable should be set to False when an upgrade is in progress, but actually not"
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
        if [ "${wait_upgrade}" == "$(( TIMEOUT - 10 ))" ] &&  check_ota_case_enabled "OCP-73352"; then
            # "${wait_upgrade}" == "$(( TIMEOUT - 10 ))" is used to make sure run check_upgrade_recommend_when_upgrade_inprogress once
            # and "TIMEOUT - 10" is used to make sure upgrade is started
            if ! check_upgrade_recommend_when_upgrade_inprogress; then
                echo "OCP-73352: failed"
                return 1
            fi
        fi
        if [[ "${UPGRADE_RHEL_WORKER_BEFOREHAND}" == "true" && ${avail} == "True" && ${progress} == "True" && ${out} == *"Unable to apply ${cluster_version}"* ]]; then
            UPGRADE_RHEL_WORKER_BEFOREHAND="triggered"
            echo -e "Upgrade stuck at updating RHEL worker, need to run the RHEL worker upgrade later...\n\n"
            return 0
        fi
    done
    if [[ ${wait_upgrade} -le 0 ]]; then
        echo -e "Upgrade checking timeout at $(date "+%F %T")\n"
        end_time=$(date "+%s")
        echo -e "Eclipsed Time: $(( ($end_time - $start_time) / 60 ))m\n"
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
        echo >&2 "History check FAILED, cluster upgrade to ${TARGET_VERSION} failed, current version is ${version}, exiting" && return 1
    fi
}

# check if any of cases is enabled via ENABLE_OTA_TEST
function check_ota_case_enabled() {
    local case_id
    local cases_array=("$@")
    for case_id in "${cases_array[@]}"; do
        # shellcheck disable=SC2076
        if [[ " ${ENABLE_OTA_TEST} " =~ " ${case_id} " ]]; then
            echo "${case_id} is enabled via ENABLE_OTA_TEST on this job."
            return 0
        fi
    done
    return 1
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
if ! check_signed; then
    echo "You're updating to an unsigned images, you must override the verification using --force flag"
    FORCE_UPDATE="true"
    if check_ota_case_enabled "OCP-30832" "OCP-27986" "OCP-24358" "OCP-56083"; then
        echo "The case need to run against a signed target image!"
        exit 1
    fi
else
    echo "You're updating to a signed images, so run the upgrade command without --force flag"
fi
if [[ "${FORCE_UPDATE}" == "false" ]]; then
    admin_ack
    cco_annotation
fi
if [[ "${UPGRADE_CCO_MANUAL_MODE}" == "oidc" ]]; then
    update_cloud_credentials_oidc
fi
upgrade
check_upgrade_status

if [[ "$UPGRADE_RHEL_WORKER_BEFOREHAND" != "triggered" ]]; then
    check_history
fi
