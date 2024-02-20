#!/bin/bash

set -o nounset
set -o pipefail

function extract_oc(){
    echo -e "Extracting oc\n"
    local retry=5 
    tmp_oc="/tmp/client"
    mkdir -p ${tmp_oc}
    while ! (env "NO_PROXY=*" "no_proxy=*" oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --command=oc --to=${tmp_oc} ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE});
    do
        echo >&2 "Failed to extract oc binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_oc}/oc /tmp -f
    which oc
    oc version --client
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
    tp_operator=("cluster-api" "platform-operators-aggregated" "olm")
    ;;
    *)
    tp_operator=()
    ;;
    esac
    echo ${tp_operator[*]}
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
    expectedCapCR=$(echo ${EXPECTED_CAPABILITIES_IN_CREDENTIALREQUEST} | sort -u|xargs)
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
    for tp_op in ${tp_op[*]}; do
        if ! check_tp_operator_notfound ${tp_op}; then
            return 1
        fi
    done
    echo "Test Passed: ${FUNCNAME[0]}"
    return 0
}

function post-OCP-53921(){
    echo "Test Start: ${FUNCNAME[0]}"
    local arch version
    arch=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "ReleaseAccepted")|.message')
    if [[ "${arch}" != *"Multi"* ]]; then
        echo "The architecture info: ${arch} is not expected!"
        return 1
    fi
    version="$(oc get clusterversion --no-headers | awk '{print $2}')"
    if [ -z "${version}" ] ; then
        echo "Fail to get cluster version!"
        return 1
    fi
    x_ver=$( echo "${version}" | cut -f1 -d. )
    y_ver=$( echo "${version}" | cut -f2 -d. )
    y_ver=$((y_ver+1))
    ver="${x_ver}.${y_ver}"
    if ! oc adm upgrade channel candidate-${ver}; then
        echo "Fail to change channel to candidate-${ver}!"
        return 1
    fi
    recommends=$(oc get clusterversion version -o json|jq -r '.status.availableUpdates')
    if [[ "${recommends}" == "null" ]]; then
        echo "No recommended update available!"
        return 1
    fi
    mapfile -t images < <(echo ${recommends}|jq -r '.[].image')
    if [ -z "${images[*]}" ]; then
        echo "No image extracted from recommended update!"
        return 1
    fi
    for image in ${images[*]}; do
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

# This func run all test cases with with checkpoints which will not break other cases,
# which means the case func called in this fun can be executed in the same cluster
# Define if the specified case should be ran or not
function run_ota_multi_test(){
    caseset=(OCP-47197)
    for case in ${caseset[*]}; do
        if ! type post-"${case}" &>/dev/null; then
            echo "WARN: no post-${case} function found" >> "${report_file}"
        else
            echo "------> ${case}"
            post-"${case}"
            if [[ $? == 0 ]]; then
                echo "PASS: post-${case}" >> "${report_file}"
            else
                echo "FAIL: post-${case}" >> "${report_file}"
            fi
        fi
    done
}

# Run single case through case ID
function run_ota_single_case(){
    if ! type post-"${1}" &>/dev/null; then
        echo "WARN: no post-${1} function found" >> "${report_file}"
    else
        echo "------> ${1}"
        post-"${1}"
        if [[ $? == 0 ]]; then
            echo "PASS: post-${1}" >> "${report_file}"
        else
            echo "FAIL: post-${1}" >> "${report_file}"
        fi
    fi
}

if [[ "${ENABLE_OTA_TEST}" == "false" ]]; then
  exit 0
fi

report_file="${ARTIFACT_DIR}/ota-test-result.txt"
export PATH=/tmp:${PATH}
extract_oc

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

set +e
if [[ "${ENABLE_OTA_TEST}" == "true" ]]; then
  run_ota_multi_test
else
  run_ota_single_case ${ENABLE_OTA_TEST}
fi
