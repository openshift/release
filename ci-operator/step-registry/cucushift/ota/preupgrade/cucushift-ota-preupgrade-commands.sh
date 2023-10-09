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
function pre-ocp-66839(){
    if [[ "${BASELINE_CAPABILITY_SET}" != "None" ]]; then
        echo "Test Skipped: ${FUNCNAME[0]}"
        return 0
    fi

    echo "Test Start: ${FUNCNAME[0]}"    
    # Extract all manifests from live cluster with --included
    manifestsDir="/tmp/pre-include-manifest"
    mkdir "${manifestsDir}"
    if ! oc adm release extract --to "${manifestsDir}" --included; then
        echo "Failed to extract manifests!"
        return 1
    fi
    # There should not be any cap annotation in all extracted manifests 
    curCap=$(grep -rh "capability.openshift.io/name:" "${manifestsDir}"|awk -F": " '{print $NF}'|sort -u)
    if [[ "${curCap}" != "" ]]; then
        echo "Caps in extracted manifests found: ${curCap}, but expected nothing"
        return 1
    fi
    # No featureset or only Default featureset annotation in all extarcted manifests
    curFS=$(grep -rh "release.openshift.io/feature-set:" "${manifestsDir}"|awk -F": " '{print $NF}'|sort -u)
    if [[ "${curFS}" != "Default" ]] && [[ "${curFS}" != "" ]]; then
        echo "Featureset in extarcted manifests: ${curFS}, but expected: Default or """
        return 1
    fi
    # Should exclude manifests with cluster-profile not used by cvo
    cluster_profile=$(oc get deployment -n openshift-cluster-version cluster-version-operator -o jsonpath='{.spec.template.spec.containers[].env[?(@.name=="CLUSTER_PROFILE")].value}')
    curProfileNum=$(grep -rl "include.release.openshift.io/${cluster_profile}:" "${manifestsDir}"|wc -l)
    manifestNum=$(ls ${manifestsDir}/*.yaml|wc -l)
    if [[ "${curProfileNum}" != "${manifestNum}" ]]; then
        echo "Extracted manifests number: ${manifestNum}, manifests number with correct cluster-profile: ${curProfileNum}"
        return 1
    fi
    
    preCredsDir="/tmp/pre-include-creds"
    tobeCredsDir="/tmp/tobe-include-creds"
    mkdir "${preCredsDir}" "${tobeCredsDir}"
    # Extract all CRs from live cluster with --included
    if ! oc adm release extract --to "${preCredsDir}" --included --credentials-requests; then
        echo "Failed to extract CRs from live cluster!"
        return 1
    fi
    if grep -r "capability.openshift.io/name:" "${preCredsDir}"; then
        echo "Extracted CRs has cap annotation, but expected nothing"
        return 1
    fi
    # Extract all CRs from tobe upgrade release payload with --included
    if ! oc adm release extract --to "${tobeCredsDir}" --included --credentials-requests "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"; then
        echo "Failed to extract CRs from tobe upgrade release payload!"
        return 1
    fi
    tobecap=$(grep -rh "capability.openshift.io/name:" "${tobeCredsDir}"|awk -F": " '{print $NF}'|sort -u|xargs)
    if [[ "${tobecap}" != "MachineAPI ImageRegistry" ]] && [[ "${tobecap}" != "ImageRegistry MachineAPI" ]]; then
        echo "Tobe gained CRs with cap annotation: ${tobecap}, but expected: MachineAPI and ImageRegistry"
        return 1
    fi
    echo "Test Passed: ${FUNCNAME[0]}"
    return 0
}

# This func run all test cases with checkpoints which will not break other cases, 
# which means the case func called in this fun can be executed in the same cluster
# Define if the specified case should be run or not
function run_ota_multi_test(){
    echo "placeholder"
}

# Run single case through case ID
function run_ota_single_case(){
    if ! type pre-ocp-"${1}" &>/dev/null; then
        echo "Test Failed: pre-ocp-${1} due to no case id found!" >> "${report_file}"
    else
        pre-ocp-"${1}"
        if [[ $? == 1 ]]; then
            echo "Test Failed: pre-ocp-${1}" >> "${report_file}"
        fi
    fi 
}
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
if [[ "${ENABLE_OTA_TEST}" == "false" ]]; then
  exit 0
elif [[ "${ENABLE_OTA_TEST}" == "true" ]]; then
  run_ota_multi_test
else
  run_ota_single_case ${ENABLE_OTA_TEST}
fi

