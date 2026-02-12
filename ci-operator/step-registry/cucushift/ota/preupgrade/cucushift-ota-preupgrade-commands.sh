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

# get prometheus object
# Parameter
#    sub_url: the sub url of prometheus api
# Example:
#    get_prometheus_api "v1/label/reason/values"
function get_prometheus_api(){
    local token url sub_url="${1}"
    token="$(oc -n openshift-monitoring create token prometheus-k8s)"
    url="$(oc get route prometheus-k8s -n openshift-monitoring --no-headers|awk '{print $2}')"
    curl -s -k -H "Authorization: Bearer $token" "https://${url}/api/${sub_url}"
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
                echo "ns found for $1!"
                return 1
            fi
        else
            echo "operator found $1!"
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
    for op_file in "${tp_op_filepaths[@]}"; do
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

function pre-OCP-32747(){
    local reason alerts alert namespace severity description state summary retry=10
    
    oc patch featuregate cluster --type json -p '[{"op": "add", "path": "/spec/featureSet", "value": "TechPreviewNoUpgrade"}]'
    while (( retry > 0 )); do
        reason=$( get_prometheus_api "v1/label/reason/values" )
        if [[ "${reason}" == *"FeatureGates_RestrictedFeatureGates_TechPreviewNoUpgrade"* ]]; then
            break
        fi
        sleep 1m
        retry=$((retry-1))
    done
    if [[ "${reason}" != *"FeatureGates_RestrictedFeatureGates_TechPreviewNoUpgrade"* ]]; then
        echo "Error: 32747 After waiting 10 minutes, FeatureGates_RestrictedFeatureGates_TechPreviewNoUpgrade still not appears"
        return 1
    fi

    retry=5
    while (( retry > 0 )); do
        alerts=$( get_prometheus_api "v1/alerts" )
        alert="$(echo "${alerts}" | yq  -r '.data.alerts[]| select(.labels.alertname == "ClusterNotUpgradeable")')"
        namespace="$(echo "${alert}" | yq -r ".labels.namespace")"
        severity="$(echo "${alert}" | yq -r ".labels.severity")"
        description="$(echo "${alert}" | yq -r ".annotations.description")"
        state="$(echo "${alert}" | yq -r ".state")"
        if [[ "${namespace}" != "openshift-cluster-version" ]] \
            || [[ "${severity}" != "info" ]] \
            || [[ "${description}" != *"In most cases, you will still be able to apply patch releases."* ]] \
            || [[ "${state}" != "pending" ]]; then
            sleep 1m
            retry=$((retry-1))
            continue
        fi
        break
    done
    echo -e "Alert ClusterNotUpgradeable at beginning:\n${alert}"
    if [[ "${namespace}" != "openshift-cluster-version" ]]; then
        echo "Error: 32747 namespace is incorrect, expected is openshift-cluster-version, but observed is ${namespace}"
        return 1
    fi
    if [[ "${severity}" != "info" ]]; then
        echo "Error: 32747 severity is incorrect, expected is info, but observed is ${severity}"
        return 1
    fi
    if [[ "${description}" != *"In most cases, you will still be able to apply patch releases."* ]]; then
        echo "Error: 32747 description is incorrect, expected is 'In most cases, you will still be able to apply patch releases.', but observed is '${description}'"
        return 1
    fi
    if [[ "${state}" != "pending" ]]; then
        echo "Error: 32747 state is incorrect, expected is pending, but observed is ${state}"
        return 1
    fi
    echo "Alert ClusterNotUpgradeable at beginning is correct"

    retry=0
    while (( retry < 70 ));do
        alerts=$( get_prometheus_api "v1/alerts" )
        alert="$(echo "${alerts}" | yq  -r '.data.alerts[]| select(.labels.alertname == "ClusterNotUpgradeable")')"
        state="$(echo "${alert}" | yq -r ".state")"
        if [[ "${state}" == "firing" ]]; then
            if [[ ${retry} -lt 60 ]]; then
                echo "Error: 32747 Alerts should be changed for at least 1 hour: https://github.com/openshift/cluster-version-operator/blob/8a8bca5df3bd89f8caab7c185f407f6a6e2697c8/install/0000_90_cluster-version-operator_02_servicemonitor.yaml#L87-L93"
                echo "${alert}"
                return 1
            fi
            break
        fi
        echo "Attempted ${retry}"
        sleep 1m
        retry=$((retry+1))
    done

    echo -e "Alert ClusterNotUpgradeable after 70 minutes is:\n${alert}"
    if [[ "${state}" != "firing" ]]; then
        echo -e "Error: 32747 Alert not changed to firing after 70 minutes"
        return 1
    fi

    summary="$(echo "${alert}" | yq -r ".annotations.summary")"
    if [[ "${summary}" != *"One or more cluster operators have been blocking minor version cluster upgrades for at least an hour."* ]]; then
        echo "Error: 32747 When state is firing, summary is incorrect, expected is 'One or more cluster operators have been blocking minor version cluster upgrades for at least an hour.', but observed is '${summary}'"
        return 1
    fi

    description="$(echo "${alert}" | yq -r ".annotations.description")"
    if [[ "${description}" != *"Reason FeatureGates_RestrictedFeatureGates_TechPreviewNoUpgrade"* ]]; then
        echo "Error: 32747 When state is firing, description is incorrect, expected is 'Reason FeatureGates_RestrictedFeatureGates_TechPreviewNoUpgrade', but observed is '${description}'"
        return 1
    fi
    echo "Alert ClusterNotUpgradeable works normal"
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
    for tp_op in "${src_tp_op[@]}"; do
        if ! check_tp_operator_notfound ${tp_op}; then
            return 1
        fi
    done

    tgt_tp_op=$(get_tp_operator ${tgt_ver})
    if [ -z "${tgt_tp_op}" ] ; then
        echo "Fail to get tp operator list on ${tgt_ver}!"
        return 1
    fi
    if ! check_manifest_annotations "${tgt_tp_op[@]}"; then
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
    "--to-multi-arch may not be used with --to, --to-image, or --to-latest" 1 \
    || return 1


    # --to <some version> --to-multi-arch -error
    verify_output \
    "proper error trying --to with to multi arch" \
    "oc adm upgrade --to 4.10.0 --to-multi-arch" \
    "--to-multi-arch may not be used with --to, --to-image, or --to-latest" 1 \
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

    # wait for status change
    sleep 60

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

    #export pull-secrets from live cluster for skopeo inspect to use
    run_command "oc extract secret/installation-pull-secrets -n openshift-image-registry --confirm --to=/tmp/secret/"
    # verify cvo image still non-hetero
    verify_output \
    "cvo image pre-transition is non-hetero" \
    "skopeo inspect --raw docker://$(oc get -n openshift-cluster-version pod -o jsonpath='{.items[0].spec.containers[0].image}') --authfile /tmp/secret/.dockerconfigjson | jq .mediaType" \
    "application/vnd.docker.distribution.manifest.v2+json" || return 1

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

function check_mcp_status() {
    local machineCount updatedMachineCount counter=0 interval=120
    machineCount=$(oc get mcp $1 -o=jsonpath='{.status.machineCount}')
    while [ $counter -lt 1800 ]
    do
        sleep ${interval}
        counter=$((counter + interval))
        echo "waiting ${counter}s"
        updatedMachineCount=$(oc get mcp $1 -o=jsonpath='{.status.updatedMachineCount}')
        if [[ ${updatedMachineCount} = "${machineCount}" ]]; then
            echo "MCP $1 updated successfully"
            break
        fi
    done
    if [[ ${updatedMachineCount} != "${machineCount}" ]]; then
        echo "Timeout to update MCP $1"
        return 1
    fi
    return 0
}

function pre-OCP-47160(){
    echo "Test Start: ${FUNCNAME[0]}"
    echo "Check the techpreview operator is not installed by default..."
    local version tp_op op tmp_manifest_dir_pre fs
    version=$(oc get clusterversion --no-headers | awk '{print $2}' | cut -d. -f1,2)
    # shellcheck disable=SC2207
    tp_op=($(get_tp_operator ${version}))
    if [ -z "${tp_op[*]}" ] ; then
        echo "Fail to get tp operator list on ${version}!"
        return 1
    fi
    for op in "${tp_op[@]}"; do
        if ! check_tp_operator_notfound ${op}; then
            return 1
        fi
    done

    echo "Check no TechPreviewNoUpgrade featureset in manifests with --included cmd..."
    tmp_manifest_dir_pre=$(mktemp -d)
    if ! oc adm release extract --included --to "${tmp_manifest_dir_pre}"; then
        echo "Failed to extract manifest!"
        return 1
    fi
    if grep -q -r "release.openshift.io/feature-set: .*TechPreviewNoUpgrade" ${tmp_manifest_dir_pre} ; then
        echo "There should not be TechPreviewNoUpgrade featureset!"
        return 1
    fi

    echo "Enable TechPreviewNoUpgrade featureset..."
    local pre_co_num expected_co_num post_co_num
    pre_co_num=$(oc get co --no-headers|wc -l)
    oc patch featuregate cluster -p '{"spec": {"featureSet": "TechPreviewNoUpgrade"}}' --type merge || true
    fs=$(oc get featuregate cluster -ojson|jq -r '.spec.featureSet')
    if [[ "${fs}" != "TechPreviewNoUpgrade" ]]; then
        echo "Fail to patch featuregate cluster!"
        return 1
    fi
    echo "Wait for MCP rollout to start..."
    if ! oc wait mcp --all --for condition=updating --timeout=300s; then
        echo "The mcp rollout does not start in 5m!"
        return 1
    fi
    if ! check_mcp_status master || ! check_mcp_status worker ; then
        echo "Fail to enable TechPreviewNoUpgrade fs!"
        return 1
    fi

    echo "Check the techpreview operator is installed..."
    for op in "${tp_op[@]}"; do
        if check_tp_operator_notfound ${op}; then
            return 1
        fi
    done
    expected_co_num=$(expr $pre_co_num + ${#tp_op[@]})
    post_co_num=$(oc get co --no-headers|wc -l)
    if (( "$expected_co_num" != "$post_co_num" )); then
        echo "Unexpected techpreview operator enabled or disabled!"
        return 1
    fi

    echo "Check upgradeable=false condition is set through 'oc adm upgrade'..."
    tmp_log=$(mktemp)
    oc adm upgrade 2>&1 | tee "${tmp_log}"
    if ! grep -q 'Upgradeable=False' "${tmp_log}" || ! grep -q "FeatureGates_RestrictedFeatureGates_TechPreviewNoUpgrade" "${tmp_log}"; then
        echo "Upgrade msg is not expected!"
        return 1
    fi

    echo "Check there should be TechPreviewNoUpgrade featureset extracted with --included cmd..."
    local manifest_tp_num manifest_fs_num tmp_manifest_dir_post
    tmp_manifest_dir_post=$(mktemp -d)
    if ! oc adm release extract --included --to "${tmp_manifest_dir_post}"; then
        echo "Failed to extract manifest!"
        return 1
    fi
    manifest_tp_num=$(grep -rh "release.openshift.io/feature-set: .*TechPreviewNoUpgrade" ${tmp_manifest_dir_post}|awk -F": " '{print $2}'|sort -u|wc -l)
    manifest_fs_num=$(grep -rh "release.openshift.io/feature-set:" ${tmp_manifest_dir_post}|awk -F": " '{print $2}'|sort -u|wc -l)
    if (( "$manifest_tp_num" != "$manifest_fs_num" )); then
        echo "There should be TechPreviewNoUpgrade in each featureset annotation!"
        return 1
    fi

    echo "Check TechPreviewNoUpgrade flag cannot be unset..."
    oc patch featuregate cluster -p '{"spec": {"featureSet": ""}}' --type merge || true
    oc patch featuregate cluster --type=json -p '[{"op":"remove", "path":"/spec/featureSet"}]' || true
    if [[ "$(oc get featuregate cluster -ojson|jq -r '.spec.featureSet')" != "TechPreviewNoUpgrade" ]]; then
        echo "Unset featureset test fail!"
        return 1
    fi
    return 0
}

function pre-OCP-47200(){
    echo "Test Start: ${FUNCNAME[0]}"
    echo "Check the techpreview operator is not installed by default..."
    local version tp_op op
    version=$(oc get clusterversion --no-headers | awk '{print $2}' | cut -d. -f1,2)
    # shellcheck disable=SC2207
    tp_op=($(get_tp_operator ${version}))
    if [ -z "${tp_op[*]}" ] ; then
        echo "Fail to get tp operator list on ${version}!"
        return 1
    fi
    # Skip cluster-api due to the mismatch between ns and operator when enabling CustomNoUpgrade fs
    if [[ ${#tp_op[@]} -eq 1 ]] && [[ "${tp_op[0]}" == "cluster-api" ]]; then
        echo "Only cluster-api tp operator avaialble in ${version}, skip the test!"
        return 1
    else
        echo "Drop cluster-api from tp operator list: ${tp_op[*]}"
        for i in "${!tp_op[@]}"; do
            if [[ "${tp_op[i]}" == "cluster-api" ]]; then
                unset 'tp_op[i]'
                echo "After dropping, the operator list is: ${tp_op[*]}"
                break
            fi
        done
    fi

    for op in "${tp_op[@]}"; do
        if ! check_tp_operator_notfound ${op}; then
            return 1
        fi
    done

    echo "Enable non-TechPreviewNoUpgrade featureset..."
    local fs_before fs_after
    fs_before=$(oc get featuregate cluster -ojson|jq -r '.spec.featureSet')
    if [[ "${fs_before}" != "null" ]]; then
        echo "The cluster was already enabled featureset unexpected: ${fs_before}"
        return 1
    fi
    oc patch featuregate cluster -p '{"spec": {"featureSet": "CustomNoUpgrade"}}' --type merge || true
    fs_after=$(oc get featuregate cluster -ojson|jq -r '.spec.featureSet')
    if [[ "${fs_after}" != "CustomNoUpgrade" ]]; then
        echo "Fail to patch featuregate cluster!"
        return 1
    fi
    echo "Wait for MCP rollout to start..."
    if ! oc wait mcp --all --for condition=updating --timeout=300s; then
        echo "The mcp rollout does not start in 5m!"
        return 1
    fi
    if ! check_mcp_status master || ! check_mcp_status worker ; then
        echo "Fail to enable CustomNoUpgrade fs!"
        return 1
    fi

    echo "Check the techpreview operator is not installed..."
    for op in "${tp_op[@]}"; do
        if ! check_tp_operator_notfound ${op}; then
            return 1
        fi
    done
    return 0
}

# This func run all test cases with checkpoints which will not break other cases, 
# which means the case func called in this fun can be executed in the same cluster
# Define if the specified case should be run or not
function run_ota_multi_test(){
    caseset=(OCP-47197)
    for case in "${caseset[@]}"; do
        if ! type pre-"${case}" &>/dev/null; then
            echo "WARN: no pre-${case} function found"
        else
            echo "------> ${case}"
            pre-"${case}"
            if [[ $? == 0 ]]; then
                echo "PASS: pre-${case}"
                export SUCCESS_CASE_SET="${SUCCESS_CASE_SET} ${case}"
            else
                echo "FAIL: pre-${case}"
                export FAILURE_CASE_SET="${FAILURE_CASE_SET} ${case}"
            fi
        fi
    done
}

# Run single case through case ID
function run_ota_single_case(){
    if ! type pre-"${1}" &>/dev/null; then
        echo "WARN: no pre-${1} function found"
    else
        echo "------> ${1}"
        pre-"${1}"
        if [[ $? == 0 ]]; then
            echo "PASS: pre-${1}"
            export SUCCESS_CASE_SET="${SUCCESS_CASE_SET} ${1}"
        else
            echo "FAIL: pre-${1}"
            export FAILURE_CASE_SET="${FAILURE_CASE_SET} ${1}"
            # case failed in the middle may leave the cluster in unusable state
            if type defer-"${1}" &>/dev/null; then
                defer-"${1}"
            fi
        fi
    fi
}

# Generate the Junit for ota-preupgrade
function createPreUpgradeJunit() {
    echo -e "\n# Generating the Junit for ota-preupgrade"
    local report_file="${ARTIFACT_DIR}/junit_ota_preupgrade.xml"
    IFS=" " read -r -a ota_success_cases <<< "${SUCCESS_CASE_SET}"
    IFS=" " read -r -a ota_failure_cases <<< "${FAILURE_CASE_SET}"
    local cases_count=$((${#ota_success_cases[@]} + ${#ota_failure_cases[@]}))
    echo '<?xml version="1.0" encoding="UTF-8"?>' > "${report_file}"
    echo "<testsuite name=\"ota preupgrade\" tests=\"${cases_count}\" failures=\"${#ota_failure_cases[@]}\">" >> "${report_file}"
    for success in "${ota_success_cases[@]}"; do
        echo "  <testcase name=\"ota preupgrade should succeed: ${success}\"/>" >> "${report_file}"
    done
    for failure in "${ota_failure_cases[@]}"; do
        echo "  <testcase name=\"ota preupgrade should succeed: ${failure}\">" >> "${report_file}"
        echo "    <failure message=\"ota preupgrade failed at ${failure}\"></failure>" >> "${report_file}"
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
createPreUpgradeJunit
