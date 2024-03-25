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

function check_manifest_annotations(){
    tmp_manifest=$(mktemp -d)
    IFS=" " read -r -a tp_operator <<< "$*"
    if ! oc adm release extract --to "${tmp_manifest}" "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"; then
        echo "Failed to extract manifest!"
        return 1
    fi
    tp_op_filepath=$(grep -rl 'release.openshift.io/feature-set: .*TechPreviewNoUpgrade.*' ${tmp_manifest}|grep -E 'clusteroperator|cluster_operator')
    mapfile -t tp_op_filepaths <<< "$tp_op_filepath"
    if (( ${#tp_operator[*]} != ${#tp_op_filepaths[*]} )); then
        echo "Unexpected number of cluster operator manifest files with correct annotation found!"
        return 1
    fi
    tp_operators=$(printf "%s " "${tp_operator[*]}")
    for op_file in ${tp_op_filepaths[*]}; do
        op_name=$(yq e '.metadata.name' ${op_file})
        if [ -z "${op_name}" ] ; then
            echo "No metadata.name in manifest!"
            return 1
        fi
        if ! grep -qw "${op_name}" <<< "${tp_operators}"; then
            echo "Unexpected operator ${op_name} found!"
            return 1
        fi
    done
    return 0
}
# Define the checkpoints/steps needed for the specific case
function pre-OCP-66839(){
    if [[ "${BASELINE_CAPABILITY_SET}" != "None" ]]; then
        echo "Test Skipped: ${FUNCNAME[0]}"
        return 0
    fi

    echo "Test Start: ${FUNCNAME[0]}"
    extract_oc || return 1
    # Extract all manifests from live cluster with --included
    manifestsDir="/tmp/pre-include-manifest"
    mkdir "${manifestsDir}"
    if ! oc adm release extract --to "${manifestsDir}" --included; then
        echo "Failed to extract manifests!"
        return 1
    fi

    # There should be only enabled cap annotaion in all extracted manifests
    curCap=$(grep -rh "capability.openshift.io/name:" "${manifestsDir}"|awk -F": " '{print $NF}'|sort -u|xargs)
    expectedCap=$(echo ${ADDITIONAL_ENABLED_CAPABILITIES} | sort -u|xargs)
    if [[ "${curCap}" != "${expectedCap}" ]]; then
        echo "Caps in extracted manifests found: ${curCap}, but expected ${expectedCap}"
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

    if [[ "${ADDITIONAL_ENABLED_CAPABILITIES}" != "" ]]; then
        curCapInCR=$(grep -rh "capability.openshift.io/name:" "${preCredsDir}"|awk -F": " '{print $NF}'|sort -u|xargs)
        if [[ "${curCapInCR}" != "${expectedCap}" ]]; then
            echo "Extracted CRs has cap annotation: ${curCapInCR}, but expected ${expectedCap}"
            return 1
        fi
    else
        if grep -r "capability.openshift.io/name:" "${preCredsDir}"; then
            echo "Extracted CRs has cap annotation, but expected nothing"
            return 1
        fi
    fi

    # Extract all CRs from tobe upgrade release payload with --included
    if ! oc adm release extract --to "${tobeCredsDir}" --included --credentials-requests "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"; then
        echo "Failed to extract CRs from tobe upgrade release payload!"
        return 1
    fi
    tobecap=$(grep -rh "capability.openshift.io/name:" "${tobeCredsDir}"|awk -F": " '{print $NF}'|sort -u|xargs)
    expectedCapCR=$(echo ${EXPECTED_CAPABILITIES_IN_CREDENTIALREQUEST} | sort -u|xargs)
    if [[ "${tobecap}" != "${expectedCapCR}" ]]; then
        echo "CRs with cap annotation: ${tobecap}, but expected: ${expectedCapCR}"
        return 1
    fi
    echo "Test Passed: ${FUNCNAME[0]}"
    return 0
}

function pre-OCP-24358(){
    local pre_proxy_spec="${SHARED_DIR}/OCP-24358_spec_pre.out"
    
    oc get proxy -ojson | jq -r '.items[].spec' > "${pre_proxy_spec}"
    if [[ ! -s "${pre_proxy_spec}" ]]; then
        echo "Fail to get proxy spec!"
        return 1
    fi
    return 0
}

function pre-OCP-47197(){
    echo "Test Start: ${FUNCNAME[0]}"
    local version 
    version="$(oc get clusterversion --no-headers | awk '{print $2}')"
    if [ -z "${version}" ] ; then
        echo "Fail to get cluster version!"
        return 1
    fi
    x_ver=$( echo "${version}" | cut -f1 -d. )
    y_ver=$( echo "${version}" | cut -f2 -d. )
    next_y_ver=$((y_ver+1))
    src_ver="${x_ver}.${y_ver}"
    tgt_ver="${x_ver}.${next_y_ver}"

    src_tp_op=$(get_tp_operator ${src_ver})
    if [ -z "${src_tp_op}" ] ; then
        echo "Fail to get tp operator list on ${src_ver}!"
        return 1
    fi
    for tp_op in ${src_tp_op[*]}; do
        if ! check_tp_operator_notfound ${tp_op}; then
            return 1
        fi
    done

    tgt_tp_op=$(get_tp_operator ${tgt_ver})
    if [ -z "${tgt_tp_op}" ] ; then
        echo "Fail to get tp operator list on ${tgt_ver}!"
        return 1
    fi
    if ! check_manifest_annotations ${tgt_tp_op[*]}; then
        echo "Fail to check annotation in target manifest"
        return 1
    else
        echo "Pass to check annotation in target manifest"
    fi
    echo "Test Passed: ${FUNCNAME[0]}"
    return 0
}

function pre-OCP-53921(){
    echo "Test Start: ${FUNCNAME[0]}"
    local arch
    arch=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "ReleaseAccepted")|.message')
    if [[ "${arch}" != *"amd64"* ]]; then
        echo "The architecture info: ${arch} is not expected!"
        return 1
    fi
    return 0
}

function pre-OCP-53907(){
    echo "Test Start: ${FUNCNAME[0]}"
    local version 
    version="$(oc get clusterversion --no-headers | awk '{print $2}')"
    if [ -z "${version}" ] ; then
        echo "Fail to get cluster version!"
        return 1
    fi
    x_ver=$( echo "${version}" | cut -f1 -d. )
    y_ver=$( echo "${version}" | cut -f2 -d. )
    y_ver=$((y_ver+1))
    ver="${x_ver}.${y_ver}"
    local retry=3
    while (( retry > 0 ));do
        versions=$(oc get clusterversion version -o json|jq -r '.status.availableUpdates[]?.version'| xargs)
        if [[ "${versions}" == "null" ]] || [[ "${versions}" != *"${ver}"* ]]; then
	    retry=$((retry - 1))
            sleep 60
            echo "No recommended update available! Retry..."
        else
            echo "Recommencded update: ${versions}"
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
    bad_metadata="true"
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
        bad_metadata="false"
        arch=$(oc adm release info ${image} -ojson|jq -r '.metadata.metadata."release.openshift.io/architecture"')
        if [[ "${arch}" != "multi" ]]; then
            echo "The architecture info ${arch} of recommended update ${image} is not expected!"
            return 1
        fi
    done
    if [[ "${bad_metadata}" == "true" ]]; then
        echo "All images' metadata is null in available update!"
        return 1
    fi
    return 0
}

function pre-OCP-69968(){
    echo "Test Start: ${FUNCNAME[0]}"
    local spec testurl="http://examplefortest.com"
    spec=$(oc get clusterversion version -ojson|jq -r '.spec')
    if [[ "${spec}" == *"signatureStores"* ]]; then
        echo "There should not be signatureStores by default!"
        return 1
    fi
    if ! oc patch clusterversion version --type merge -p "{\"spec\": {\"signatureStores\": [{\"url\": \"${testurl}\"}]}}"; then
        echo "Fail to patch clusterversion signatureStores!"
        return 1
    fi
    signstore=$(oc get clusterversion version -ojson|jq -r '.spec.signatureStores[].url')
    if [[ "${signstore}" != "${testurl}" ]]; then
        echo "Fail to set clusterversion signatureStores!"
        return 1
    fi
    return 0
}

function pre-OCP-69948(){
    echo "Test Start: ${FUNCNAME[0]}"
    local spec teststore="https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release"
    spec=$(oc get clusterversion version -ojson|jq -r '.spec')
    if [[ "${spec}" == *"signatureStores"* ]]; then
        echo "There should not be signatureStores by default!"
        return 1
    fi
    if ! oc patch clusterversion version --type merge -p "{\"spec\": {\"signatureStores\": [{\"url\": \"${teststore}\"}]}}"; then
        echo "Fail to patch clusterversion signatureStores!"
        return 1
    fi
    signstore=$(oc get clusterversion version -ojson|jq -r '.spec.signatureStores[].url')
    if [[ "${signstore}" != "${teststore}" ]]; then
        echo "Fail to set clusterversion signatureStores!"
        return 1
    fi
    return 0
}


function pre-OCP-56083(){
    echo "Pre Test Start: OCP-56083"
    echo "Unset the upgrade channel"
    local  tmp_log result
    tmp_log=$(mktemp)
    oc adm upgrade channel --allow-explicit-channel  2>&1 | tee "${tmp_log}" 
    result=$(oc get clusterversion/version -ojson | jq -r '.spec.channel')
    if [[ "${result}" == null ]] || [[ -z "${result}" ]]; then
       echo "Successfully cleared the upgrade channel"
       return 0 
    fi
    echo "Failed to clear Upgrade Channel"
    cat "${tmp_log}" 
    return 1
}
# This func run all test cases with checkpoints which will not break other cases, 
# which means the case func called in this fun can be executed in the same cluster
# Define if the specified case should be run or not
function run_ota_multi_test(){
    caseset=(OCP-47197)
    for case in ${caseset[*]}; do
        if ! type pre-"${case}" &>/dev/null; then
            echo "WARN: no pre-${case} function found" >> "${report_file}"
        else
            echo "------> ${case}"
            pre-"${case}"
            if [[ $? == 0 ]]; then
                echo "PASS: pre-${case}" >> "${report_file}"
            else
                echo "FAIL: pre-${case}" >> "${report_file}"
            fi
        fi
    done
}

# Run single case through case ID
function run_ota_single_case(){
    if ! type pre-"${1}" &>/dev/null; then
        echo "WARN: no pre-${1} function found" >> "${report_file}"
    else
        echo "------> ${1}"
        pre-"${1}"
        if [[ $? == 0 ]]; then
            echo "PASS: pre-${1}" >> "${report_file}"
        else
            echo "FAIL: pre-${1}" >> "${report_file}"
        fi
    fi
}

if [[ "${ENABLE_OTA_TEST}" == "false" ]]; then
  exit 0
fi

report_file="${ARTIFACT_DIR}/ota-test-result.txt"
export PATH=/tmp:${PATH}
which oc
oc version --client
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
