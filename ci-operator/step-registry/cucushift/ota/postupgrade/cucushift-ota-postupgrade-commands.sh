#!/bin/bash

set -o nounset
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function get_tp_operator(){
    local short_version=$1
    case ${short_version} in
    "4.14")
    tp_operator=("cluster-api" "platform-operators-aggregated")
    ;;
    "4.15")
    tp_operator=("cluster-api" "platform-operators-aggregated" "olm")
    ;;
    "4.16")
    tp_operator=("cluster-api" "olm")
    ;;
    "4.17")
    tp_operator=("cluster-api" "olm")
    ;;
    *)
    tp_operator=("cluster-api")
    ;;
    esac
    echo "${tp_operator[@]}"
}

function check_tp_operator_notfound(){
    local try=0 max_retries=2
    declare -A tp_resourece=(
        ["cluster-api"]="openshift-cluster-api"
        ["platform-operators-aggregated"]="openshift-platform-operators"
        ["olm"]="openshift-cluster-olm-operator"
    )
    if [ -z "${tp_resourece[$1]}" ] ; then
        echo "No expected ns configured for $1!"
        return 1
    fi
    tmp_log=$(mktemp)
    while (( try < max_retries )); do
        oc get co $1 2>&1 | tee "${tmp_log}"
        if grep -q 'NotFound' "${tmp_log}"; then
            oc get ns ${tp_resourece[$1]} 2>&1 | tee "${tmp_log}"
            if grep -q 'NotFound' "${tmp_log}"; then
                (( try += 1 ))
                sleep 60
            else
                echo "Unexpected ns found for $1!"
                return 1
            fi
        else
            echo "Unexpected operator found $1!"
            return 1
        fi
    done
    if (( ${try} >= ${max_retries} )); then
        echo "Not found the tp operator $1"
        return 0
    fi
}

function verify_output(){
    local out message="${1}" cmd="${2}" expected="${3}"
    if ! out=$(eval "${cmd}" 2>&1); then
        echo >&2 "Failed to execute \"${cmd}\" while verifying ${message}, received \"${out}\", exiting" && return 1
    fi
    if ! [[ "${out}" == *"${expected}"* ]]; then
        echo >&2 "Failed verifying ${message} contains \"${expected}\": unexpected \"${out}\", exiting" && return 1
    fi
    echo "passed verifying ${message}"
    return 0
}

# Define the checkpoints/steps needed for the specific case
function post-OCP-66839(){
    if [[ "${BASELINE_CAPABILITY_SET}" != "None" ]]; then
        echo "Test Skipped: ${FUNCNAME[0]}"
        return 0
    fi
    
    echo "Test Start: ${FUNCNAME[0]}"
    credsDir="/tmp/post-include-creds"
    mkdir "${credsDir}"
    if ! oc adm release extract --to "${credsDir}" --included --credentials-requests; then
        echo "Failed to extract manifests!"
        return 1
    fi
    # New gained cap annotation should be in extracted creds 
    newCap=$(grep -rh "capability.openshift.io/name:" "${credsDir}"|awk -F": " '{print $NF}'|sort -u|xargs)
    expectedCapCR=$(echo ${EXPECTED_CAPABILITIES_IN_CREDENTIALREQUEST_POST} | tr ' ' '\n'|sort -u|xargs)
    if [[ "${newCap}" != "${expectedCapCR}" ]]; then
        echo "CRs with cap annotation: ${newCap}, but expected: ${expectedCapCR}"
        return 1
    fi
    echo "Test Passed: ${FUNCNAME[0]}"
    return 0
}

function post-OCP-24358(){
    local pre_proxy_spec="${SHARED_DIR}/OCP-24358_spec_pre.out"
    local post_proxy_spec="${SHARED_DIR}/OCP-24358_spec_post.out"
    local ret=0 verified

    oc get proxy -ojson | jq -r '.items[].spec' > "${post_proxy_spec}"
    if [[ ! -s "${post_proxy_spec}" ]]; then
        echo "Fail to get proxy spec!"
        ret=1
    fi
    sdiff "${pre_proxy_spec}" "${post_proxy_spec}" || ret=$?
    if [[ ${ret} != 0 ]]; then
        echo "cluster proxy spec get changed afer upgrade!"
    fi
    verified=$(oc get clusterversion -o json | jq -r '.items[0].status.history[0].verified')
    if [[ "${verified}" != "true" ]]; then
        echo "cv.items[0].status.history.verified is ${verified}"
        ret=1
    fi

    return $ret
}

function post-OCP-21588(){
    local ret=0 verified

    verified=$(oc get clusterversion -o json | jq -r '.items[0].status.history[0].verified')
    if [[ "${verified}" != "false" ]]; then
        echo "cv.items[0].status.history.verified is ${verified}"
        ret=1
    fi

    return $ret
}

function post-OCP-53907(){
    echo "Test Start: ${FUNCNAME[0]}"
    local arch 
    arch=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "ReleaseAccepted")|.message')
    if [[ "${arch}" != *"architecture=\"Multi\""* ]]; then
        echo "The architecture info: ${arch} is not expected!"
        return 1
    fi
    return 0
}

function post-OCP-47197(){
    echo "Test Start: ${FUNCNAME[0]}"
    local version 
    version="$(oc get clusterversion --no-headers | awk '{print $2}')"
    if [ -z "${version}" ] ; then
        echo "Fail to get cluster version!"
        return 1
    fi
    x_ver=$( echo "${version}" | cut -f1 -d. )
    y_ver=$( echo "${version}" | cut -f2 -d. )
    ver="${x_ver}.${y_ver}"

    tp_op=$(get_tp_operator ${ver})
    if [ -z "${tp_op}" ] ; then
        echo "Fail to get tp operator list on ${ver}!"
        return 1
    fi
    for tp_op in "${tp_op[@]}"; do
        if ! check_tp_operator_notfound ${tp_op}; then
            return 1
        fi
    done
    echo "Test Passed: ${FUNCNAME[0]}"
    return 0
}

function post-OCP-53921(){
    echo "Test Start: ${FUNCNAME[0]}"
    local version recommends x_ver y_ver ver images metadata
    version="$(oc get clusterversion --no-headers | awk '{print $2}')"
    if [ -z "${version}" ] ; then
        echo "Fail to get cluster version!"
        return 1
    fi
    pre_recommended_versions=$(oc get clusterversion version -o json|jq -r '.status.availableUpdates[]?.version'| xargs)
    if [[ "${pre_recommended_versions}" == *"${version}"* ]]; then
        echo "Current version ${version} should not be in recommended updates: ${pre_recommended_versions}"
        return 1
    else
        echo "Before channel update, no installed version found in recommended updates as expected!"
    fi
    x_ver=$( echo "${version}" | cut -f1 -d. )
    y_ver=$( echo "${version}" | cut -f2 -d. )
    y_ver=$((y_ver+1))
    ver="${x_ver}.${y_ver}"
    if ! oc adm upgrade channel candidate-${ver}; then
        echo "Fail to change channel to candidate-${ver}!"
        return 1
    fi
    local retry=3
    while (( retry > 0 ));do
        post_recommended_versions=$(oc get clusterversion version -o json|jq -r '.status.availableUpdates[]?.version'| xargs)
        if [[ -z "${post_recommended_versions}" ]]; then
            retry=$((retry - 1))
            sleep 60
            echo "No recommended update available after updating channel! Retry..."
        else
            if [[ "${post_recommended_versions}" == *"${version}"* ]]; then
                echo "Current version ${version} should not be in recommended updates: ${post_recommended_versions}!"
                return 1
            fi
            echo "After channel update, no installed version found in recommended updates as expected!"
            break
        fi
    done
    if (( retry == 0 )); then
        echo "Timeout to get recommended update!" 
        return 1
    fi
    recommends=$(oc get clusterversion version -o json|jq -r '.status.availableUpdates')
    mapfile -t images < <(echo ${recommends}|jq -r '.[].image')
    if [ -z "${images[*]}" ]; then
        echo "No image extracted from recommended update!"
        return 1
    fi
    for image in "${images[@]}"; do
        if [[ "${image}" == "null" ]] ; then
            echo "No image info!"
            return 1
        fi
        metadata=$(oc adm release info ${image} -ojson|jq .metadata.metadata)
        if [[ "${metadata}" == "null" ]]; then
            echo "No metadata for recommended update ${image}!"
            continue
        fi
        if [[ "${metadata}" != *"multi"* ]]; then
            echo "The architecture info ${metadata} of recommended update ${image} is not expected!"
            return 1
        fi
    done
    return 0
}

function post-OCP-56083(){
    echo "Post Test Start: OCP-56083"
    echo "Upgrade cluster when channel is unset"
    local  expected_msg result accepted_risk_result
    expected_msg='Precondition "ClusterVersionRecommendedUpdate" failed because of "NoChannel": Configured channel is unset, so the recommended status of updating from'
    result=$(oc get clusterversion/version -ojson | jq -r '.status.conditions[]|select(.type == "ReleaseAccepted").status')
    if  [[ "${result}" == "True" ]]; then
        accepted_risk_result=$(oc get clusterversion/version -ojson | jq -r '.status.history[0].acceptedRisks')
        echo "${accepted_risk_result}"
        if [[ "${accepted_risk_result}" =~ ${expected_msg} ]]; then
            echo "history.acceptedRisks complains ClusterVersion RecommendedUpdate failure with NoChannel"
            echo "Test Passed: OCP-56083"
            return 0 
        else
            echo "Error: history.acceptedRisks Not complains about ClusterVersion RecommendedUpdate failure with NoChannel"
        fi
    else
        echo "Error: Release Not Accepted"
        echo "clusterversion release accepted status value: ${result}"
    fi
    echo "Test Failed: OCP-56083"
    return 1
}

function post-OCP-60396(){
    echo "Test Start: ${FUNCNAME[0]}"
    verify_output \
    "cvo image is manifest.list" \
    "skopeo inspect --raw docker://$(oc get -n openshift-cluster-version pod -o jsonpath='{.items[0].spec.containers[0].image}') | jq .mediaType" \
    "application/vnd.docker.distribution.manifest.list.v2+json" \
    || return 1

    TARGET_VERSION="$(oc get clusterversion version -ojsonpath='{.status.history[0].version}')"
    TARGET_MINOR_VERSION="$(echo "${TARGET_VERSION}" | cut -f2 -d.)"
    # rollback on 4.16+
    if [[ "${TARGET_MINOR_VERSION}" -ge "16" ]] ; then
        export OC_ENABLE_CMD_UPGRADE_ROLLBACK="true"
        SOURCE_VERSION="$(oc get clusterversion version -ojsonpath='{.status.history[1].version}')"
        SOURCE_IMAGE="$(oc get clusterversion version -ojsonpath='{.status.history[1].image}')"
        TARGET_IMAGE="$(oc get clusterversion version -ojsonpath='{.status.history[0].image}')" 
        out="$(oc adm upgrade rollback 2>&1 || true)" # expecting an error, capture and don't fail
        expected="error: previous version ${SOURCE_VERSION} (${SOURCE_IMAGE}) is greater than or equal to current version ${TARGET_VERSION} (${TARGET_IMAGE}).  Use 'oc adm upgrade ...' to update, and not this rollback command."
        if [[ ${out} != *"${expected}"* ]]; then
            echo -e "to-multi rollback reject step failed. \nexpecting: \"${expected}\" \nreceived: \"${out}\""
            return 1
        else
            echo "to-multi rollback reject step passed."
        fi
    fi
}

function post-OCP-60397(){
    echo "Test Start: ${FUNCNAME[0]}"
    verify_output \
    "cvo image is manifest.list" \
    "skopeo inspect --raw docker://$(oc get -n openshift-cluster-version pod -o jsonpath='{.items[0].spec.containers[0].image}') | jq .mediaType" \
    "application/vnd.docker.distribution.manifest.list.v2+json"
}

function post-OCP-23799(){
    export OC_ENABLE_CMD_UPGRADE_ROLLBACK="true" #OCPBUGS-33905, rollback is protected by env feature gate now
    SOURCE_VERSION="$(oc get clusterversion version -ojsonpath='{.status.history[1].version}')"
    TARGET_VERSION="$(oc get clusterversion version -ojsonpath='{.status.history[0].version}')"
    out="$(oc adm upgrade rollback 2>&1 || true)" # expecting an error, capture and don't fail
    expected="error: ${SOURCE_VERSION} is less than the current target ${TARGET_VERSION} and matches the cluster's previous version, but rollbacks that change major or minor versions are not recommended."
    if [[ ${out} != "${expected}" ]]; then
        echo -e "to-latest rollback reject step failed. \nexpecting: \"${expected}\" \nreceived: \"${out}\""
        return 1
    else
        echo "to-latest rollback reject step passed."
    fi
}

# This func run all test cases with with checkpoints which will not break other cases,
# which means the case func called in this fun can be executed in the same cluster
# Define if the specified case should be ran or not
function run_ota_multi_test(){
    caseset=(OCP-47197)
    for case in "${caseset[@]}"; do
        if ! type post-"${case}" &>/dev/null; then
            echo "WARN: no post-${case} function found"
        else
            echo "------> ${case}"
            post-"${case}"
            if [[ $? == 0 ]]; then
                echo "PASS: post-${case}"
                export SUCCESS_CASE_SET="${SUCCESS_CASE_SET} ${case}"
            else
                echo "FAIL: post-${case}"
                export FAILURE_CASE_SET="${FAILURE_CASE_SET} ${case}"
            fi
        fi
    done
}

# Run single case through case ID
function run_ota_single_case(){
    if ! type post-"${1}" &>/dev/null; then
        echo "WARN: no post-${1} function found"
    else
        echo "------> ${1}"
        post-"${1}"
        if [[ $? == 0 ]]; then
            echo "PASS: post-${1}"
            export SUCCESS_CASE_SET="${SUCCESS_CASE_SET} ${1}"
        else
            echo "FAIL: post-${1}"
            export FAILURE_CASE_SET="${FAILURE_CASE_SET} ${1}"
        fi
    fi
}

# Generate the Junit for ota-postupgrade
function createPostUpgradeJunit() {
    echo -e "\n# Generating the Junit for ota-postupgrade"
    local report_file="${ARTIFACT_DIR}/junit_ota_postupgrade.xml"
    IFS=" " read -r -a ota_success_cases <<< "${SUCCESS_CASE_SET}"
    IFS=" " read -r -a ota_failure_cases <<< "${FAILURE_CASE_SET}"
    local cases_count=$((${#ota_success_cases[@]} + ${#ota_failure_cases[@]}))
    echo '<?xml version="1.0" encoding="UTF-8"?>' > "${report_file}"
    echo "<testsuite name=\"ota postupgrade\" tests=\"${cases_count}\" failures=\"${#ota_failure_cases[@]}\">" >> "${report_file}"
    for success in "${ota_success_cases[@]}"; do
        echo "  <testcase name=\"ota postupgrade should succeed: ${success}\"/>" >> "${report_file}"
    done
    for failure in "${ota_failure_cases[@]}"; do
        echo "  <testcase name=\"ota postupgrade should succeed: ${failure}\">" >> "${report_file}"
        echo "    <failure message=\"ota postupgrade failed at ${failure}\"></failure>" >> "${report_file}"
        echo "  </testcase>" >> "${report_file}"
    done
    echo '</testsuite>' >> "${report_file}"
}

if [[ "${ENABLE_OTA_TEST}" == "false" ]]; then
  exit 0
fi

# oc cli is injected from release:target
run_command "which oc"
run_command "oc version --client"

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi
export SUCCESS_CASE_SET=""
export FAILURE_CASE_SET=""
set +e

if [[ "${ENABLE_OTA_TEST}" == "true" ]]; then
  run_ota_multi_test
else
  run_ota_single_case ${ENABLE_OTA_TEST}
fi
createPostUpgradeJunit
