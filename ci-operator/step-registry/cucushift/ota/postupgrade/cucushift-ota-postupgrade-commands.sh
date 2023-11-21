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

# This func run all test cases with with checkpoints which will not break other cases,
# which means the case func called in this fun can be executed in the same cluster
# Define if the specified case should be ran or not
function run_ota_multi_test(){
    echo "placeholder"
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
