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
    "4.18")
    tp_operator=("cluster-api" "olm")
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

function verify_output(){
    local out rc message="${1}" cmd="${2}" expected="${3}" expected_rc="${4:-0}"
    out=$(eval "${cmd}" 2>&1); rc=$?
    if [[ "${rc}" -ne "${expected_rc}" ]]; then
        echo >&2 -e "Failed to execute \"${cmd}\" while verifying ${message} \nunexpected rcode ${rc} expecting ${expected_rc} \nreceived \"${out}\" \nexiting" && return 1
    fi
    if ! [[ "${out}" == *"${expected}"* ]]; then
        echo >&2 "Failed verifying ${message} contains \"${expected}\": unexpected \"${out}\", exiting" && return 1
    fi
    echo "passed verifying ${message}"
    return 0 # not really needed cause return 0 is default, but adding for consistency
}

function switch_channel() {
    local SOURCE_VERSION SOURCE_XY_VERSION ret chan="${1:-candidate}"
    if [[ "$(oc get clusterversion version -o jsonpath='{.spec.channel}')" == *"${chan}"* ]]; then
        echo "skip switching channel, already on ""${chan}"
        return 0
    fi
    if ! SOURCE_VERSION="$(oc get clusterversion version -o jsonpath='{.status.history[0].version}' 2>&1 )"; then
        echo >&2 "Failed to run oc get clusterversion version, received \"${SOURCE_VERSION}\", exiting" && return 1
    fi
    SOURCE_XY_VERSION="$(cut -f1,2 -d. <<< "${SOURCE_VERSION}")"
    if [[ -z "${SOURCE_XY_VERSION}" ]]; then
        echo >&2 "Failed to get version, exiting" && return 1
    fi
    echo "Switch upgrade channel to ""${chan}""-""${SOURCE_XY_VERSION}""..."
    oc adm upgrade channel --allow-explicit-channel "${chan}-${SOURCE_XY_VERSION}"
    ret="$(oc get clusterversion version -o jsonpath='{.spec.channel}')"
    if [[ "${ret}" != "${chan}-${SOURCE_XY_VERSION}" ]]; then
        echo >&2 "Failed to switch channel, received ""${ret}"", exiting" && return 1
    fi
    return 0
}

function preserve_graph(){
    if ! upstream=$(oc get clusterversion version -o jsonpath='{.spec.upstream}'); then
        echo >&2 "Failed to execute get spec upstream, exiting" && return 1
    fi
    if [[ -z "${upstream}" ]]; then
        upstream="empty"
    else
        # # retcode=$(curl --head --silent --write-out "%{http_code}" --output /dev/null "${upstream}")
        # # if [[ $retcode -ne 200 ]]; then
        # #     echo >&2 "Failed get valid accessable upstream graph, received: \"${retcode}\" for \"${upstream}\", exiting" && return 1
        # relaxing upstream url to check just for sane url
        if [[ "${upstream}" != "https"* ]]; then
            echo "failed to get valid upstream. expecting https... in \"${upstream}\"" && return 1
        else
            echo "found a valid upstream \"${upstream}\""
        fi
    fi
    export upstream
    return 0
}

function set_upstream_graph(){
    if [[ "${1}" == "empty" ]]; then
        verify_output \
        "set default upstream graph by removing spec upstream" \
        "oc patch clusterversion/version --type=json --patch='[{\"op\": \"remove\", \"path\": \"/spec/upstream\"}]'" \
        "clusterversion.config.openshift.io/version patched" \
        || return 1
    else
        verify_output \
        "set upstream graph to ${1}" \
        "oc patch clusterversion/version --type=merge --patch '{\"spec\":{\"upstream\":\"${1}\"}}'" \
        "clusterversion.config.openshift.io/version patched" \
        || return 1
    fi
    return 0
}

function verify_nonhetero(){
    # return not required for single command, its the return by default
    verify_output \
    "cvo image pre-transition is non-hetero" \
    "skopeo inspect --raw docker://$(oc get -n openshift-cluster-version pod -o jsonpath='{.items[0].spec.containers[0].image}') | jq .mediaType" \
    "application/vnd.docker.distribution.manifest.v2+json"
}

function verify_retrieved_updates(){
    verify_output \
    "RetrievedUpdates condition is True" \
    "oc get clusterversion/version -o jsonpath='{.status.conditions[?(@.type==\"RetrievedUpdates\")].status}'" \
    "True"
}

# Define the checkpoints/steps needed for the specific case
function pre-OCP-66839(){
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

    # There should be only enabled cap annotaion in all extracted manifests
    curCap=$(grep -rh "capability.openshift.io/name:" "${manifestsDir}"|awk -F": " '{print $NF}'|sort -u|xargs)
    expectedCap=$(echo ${EXPECTED_CAPABILITIES_IN_MANIFEST} | tr ' ' '\n'|sort -u|xargs)
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

    curCapInCR=$(grep -rh "capability.openshift.io/name:" "${preCredsDir}"|awk -F": " '{print $NF}'|sort -u|xargs)
    expectedCapCRPre=$(echo ${EXPECTED_CAPABILITIES_IN_CREDENTIALREQUEST_PRE} | tr ' ' '\n'|sort -u|xargs)
    if [[ "${curCapInCR}" != "${expectedCapCRPre}" ]]; then
        echo "Extracted CRs has cap annotation: ${curCapInCR}, but expected ${expectedCapCRPre}"
        return 1
    fi

    # Extract all CRs from tobe upgrade release payload with --included
    if ! oc adm release extract --to "${tobeCredsDir}" --included --credentials-requests "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"; then
        echo "Failed to extract CRs from tobe upgrade release payload!"
        return 1
    fi
    tobecap=$(grep -rh "capability.openshift.io/name:" "${tobeCredsDir}"|awk -F": " '{print $NF}'|sort -u|xargs)
    expectedCapCRPost=$(echo ${EXPECTED_CAPABILITIES_IN_CREDENTIALREQUEST_POST} | tr ' ' '\n'|sort -u|xargs)
    if [[ "${tobecap}" != "${expectedCapCRPost}" ]]; then
        echo "CRs with cap annotation: ${tobecap}, but expected: ${expectedCapCRPost}"
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

function pre-OCP-56173(){
    echo "Test Start: ${FUNCNAME[0]}"
    local version image
    version="$(oc get clusterversion --no-headers | awk '{print $2}')"
    if [ -z "${version}" ] ; then
        echo "Fail to get cluster version!"
        return 1
    fi
    image="$(oc get clusterversion version -ojson | jq -r ".status.history[0].image")"
    if [ -z "${image}" ] ; then
        echo "Fail to get cluster image!"
        return 1
    fi
    
    cd ${SHARED_DIR}/ota_test_repo || return
    python cucushift-ota-preupgrade-commands.py -e '[
      {
        "version": "'${version}'",
        "payload": "'${image}'"
      }
    ]' -o "56173.json"
    git add 56173.json
    git commit -m 'Prepare test data for OCP-56173'
    cd - || return
}

function pre-OCP-60396(){
    echo "Test Start: ${FUNCNAME[0]}"
    # verify cvo image non-hetero
    verify_nonhetero || return 1

    # set chan candidate
    switch_channel "candidate" || return 1

    # check RetrievedUpdates=True
    verify_retrieved_updates || return 1

    # --to-image <some pullspec> --to-multi-arch - error
    verify_output \
    "proper error trying --to-image with to multi arch" \
    "oc adm upgrade --allow-explicit-upgrade --to-image quay.io/openshift-release-dev/ocp-release@sha256:f44f1570d0b88a75034da9109211bb39672bc1a5d063133a50dcda7c12469ca7 --to-multi-arch" \
    "--to-multi-arch may not be used with --to or --to-image" 1 \
    || return 1


    # --to <some version> --to-multi-arch -error
    verify_output \
    "proper error trying --to with to multi arch" \
    "oc adm upgrade --to 4.10.0 --to-multi-arch" \
    "--to-multi-arch may not be used with --to or --to-image" 1 \
    || return 1

    # verify not progressing.
    verify_output \
    "Cluster Progressing is False" \
    "oc get clusterversion/version -o jsonpath='{.status.conditions[?(@.type==\"Progressing\")].status}'" \
    "False"  \
    || return 1

    # create Invalid=True by applying invalid .spec.desiredUpdate
    verify_output \
    "patching cvo for Invalid=True" \
    "oc patch clusterversion/version --type=merge --patch '{\"spec\":{\"desiredUpdate\":{\"force\":true} }}'" \
    "clusterversion.config.openshift.io/version patched"  \
    || return 1

    # wait for cvo condition
    sleep 10s

    # check cvo invalid=true 
    verify_output \
    "check cvo Invalid is True" \
    "oc get clusterversion/version -o jsonpath='{.status.conditions[?(@.type==\"Invalid\")].status}'" \
    "True"  \
    || return 1

    # apply to-multi-arch -error 
    verify_output \
    "to-multi-arch error is received mentioning Invalid condition" \
    "oc adm upgrade --to-multi-arch" \
    "InvalidClusterVersion" 1 \
    || return 1

    # verify not progressing.
    verify_output \
    "Cluster Progressing is False" \
    "oc get clusterversion/version -o jsonpath='{.status.conditions[?(@.type==\"Progressing\")].status}'" \
    "False" \
    || return 1

    return 0
}

function pre-OCP-60397(){
    echo "Test Start: ${FUNCNAME[0]}"
    # verify cvo image non-hetero
    verify_nonhetero || return 1

    # preserve graph
    preserve_graph  || return 1 # exports "upstream"

    # set chan stable-xx
    switch_channel "stable" || return 1

    # set testing graph
    set_upstream_graph "https://arm64.ocp.releases.ci.openshift.org/graph" || return 1

    # check RetrievedUpdates=True
    verify_retrieved_updates  || return 1

    # apply to-multi-arch command
    verify_output \
    "try multiarch command while on a single-arch graph" \
    "oc adm upgrade --to-multi-arch" \
    "Requested update to multi cluster architecture" \
    || return 1

    # wait no more progressing
    sleep 60

    # check cluster architecture is still arm64
    verify_output \
    "cluster architecture is still arm64" \
    "oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type==\"ReleaseAccepted\")].message}'" \
    "architecture=\"arm64\"" \
    || return 1

    # verify cvo image still non-hetero
    verify_nonhetero || return 1

    # clear the upgrade
    if ! SOURCE_VERSION="$(oc get clusterversion version -o jsonpath='{.status.history[0].version}' 2>&1 )"; then
        echo >&2 "Failed to run oc get clusterversion version, received \"${SOURCE_VERSION}\", exiting" && return 1
    fi
    verify_output \
    "clear to-multi-arch" \
    "oc adm upgrade --clear" \
    "${SOURCE_VERSION}" \
    || return 1

    # restore graph
    set_upstream_graph "${upstream}" || return 1
    
    # set chan candidate-xx
    switch_channel "candidate" || return 1

    # wait no more progressing
    sleep 60

    # check RetrievedUpdates=True
    verify_retrieved_updates || return 1

    return 0
}

function defer-OCP-60397(){
    echo "Defer Recovery: ${FUNCNAME[0]}"
    oc adm upgrade --clear || true
    set_upstream_graph "${upstream:-empty}"
    switch_channel "candidate"
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
            # case failed in the middle may leave the cluster in unusable state
            if type defer-"${1}" &>/dev/null; then
                defer-"${1}"
            fi
        fi
    fi
}

if [[ "${ENABLE_OTA_TEST}" == "false" ]]; then
  exit 0
fi

report_file="${ARTIFACT_DIR}/ota-test-result.txt"
# oc cli is injected from release:target
run_command "which oc"
run_command "oc version --client"

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
