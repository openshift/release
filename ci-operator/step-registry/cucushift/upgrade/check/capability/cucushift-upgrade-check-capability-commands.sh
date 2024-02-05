#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; create_postupgrade_junit' EXIT TERM

# Generate the Junit for cap check
function create_postupgrade_junit() {
    echo "Generating the Junit for post upgrade check on capability"
    filename="cluster upgrade"
    testsuite="cluster upgrade"
    subteam="OTA"
    if (( FRC == 0 )); then
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="$SECONDS">
  <testcase name="${subteam}:Post upgrade check on capability should succeed or skip"/>
</testsuite>
EOF
    else
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="$SECONDS">
  <testcase name="${subteam}:Post upgrade check on capability should succeed">
    <failure message="">Post upgrade check on capability failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

# Get capabilities string based on release version and capset
# Need update when new cap set pops up
function get_caps_for_version_capset() {
    local version=$1
    local cap_index=$2

    if [ -z "${version}" ] || [ -z "${cap_index}" ]; then
        echo "ERROR: Missing required arguments"
        return 1
    fi

    major_version=$( echo "${version}" | cut -f1 -d. )
    minor_version=$( echo "${version}" | cut -f2 -d. )
    if [[ "${cap_index}" == "vCurrent" ]]; then
        cap_index="v${major_version}.${minor_version}"
    fi

    local caps_string=""
    case ${cap_index} in
    "None")
    ;;
    "v4.11")
    caps_string="baremetal marketplace openshift-samples"   
    (( minor_version >=14 && major_version == 4 )) && caps_string="${caps_string} MachineAPI"
    ;;
    "v4.12")
    caps_string="baremetal marketplace openshift-samples Console Insights Storage CSISnapshot"
    (( minor_version >=14 && major_version == 4 )) && caps_string="${caps_string} MachineAPI"
    ;;
    "v4.13")
    caps_string="baremetal marketplace openshift-samples Console Insights Storage CSISnapshot NodeTuning"
    (( minor_version >=14 && major_version == 4 )) && caps_string="${caps_string} MachineAPI"
    ;;
    "v4.14")
    caps_string="baremetal marketplace openshift-samples Console Insights Storage CSISnapshot NodeTuning MachineAPI Build DeploymentConfig ImageRegistry"
    ;;
    "v4.15")
    caps_string="baremetal marketplace openshift-samples Console Insights Storage CSISnapshot NodeTuning MachineAPI Build DeploymentConfig ImageRegistry OperatorLifecycleManager CloudCredential"
    ;;
    *)
    caps_string="baremetal marketplace openshift-samples Console Insights Storage CSISnapshot NodeTuning MachineAPI Build DeploymentConfig ImageRegistry OperatorLifecycleManager CloudCredential"
    ;;
    esac

    echo $caps_string
}

# Extract manifests from release
function extract_manifests() {
    # echo "Extracing manifests..."
    local work_dir="$1"
    local release="$2"
    #local tmp_known_caps

    # Check if the directory exists
    if [ ! -d "${work_dir}" ] || [ -z "${release}" ]; then
        echo "ERROR: Missing required arguments"
        return 1
    fi

    # Extract manifests
    if ! oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --to ${work_dir} --from ${release}; then
        echo "ERROR: Extracting manifest failed"
        return 1
    fi
}

# Get implicitly enabled capabilities from cluster
function get_actual_implicit_caps {
    # echo "Getting actual implicitly enabled caps in cluster..."
    local tmp_capabilities implicit_status implicit_message
    # Obtain ImplicitlyEnabledCapabilities condition status from cluster
    if ! implicit_status=$(oc get clusterversion version -o json | jq -r '.status.conditions[] | select(.type == "ImplicitlyEnabledCapabilities").status'); then
        echo "ERROR: Get implicitly enabled caps failed"
        return 1
    fi
    if [ "$implicit_status" = "False" ]; then
        echo "INFO: No implicitly enabled capabilities in the cluster"
        return
    fi
    # Obtain ImplicitlyEnabledCapabilities condition message from cluster
    if ! implicit_message=$(oc get clusterversion version -o json | jq -r '.status.conditions[] | select(.type == "ImplicitlyEnabledCapabilities").message'); then
        echo "ERROR: Get implicitly enabled caps failed"
        return 1
    fi

    # Parse the message to extract implicit caps
    # The condition message could be "The following capabilities could not be disabled: Console, Insights, Storage"
    tmp_capabilities=$(echo "$implicit_message" | grep -oE 'could not be disabled: (.*)' | cut -d':' -f2)
    actual_implicit_caps=$(echo "$tmp_capabilities" | awk -F', ' '{ for (i=1; i<=NF; i++) print $i }')
    # echo "Actual implicitly enabled capabilities list is ${actual_implicit_caps}"
}

# Get new capabilities introduced in target release compared to source release
# It doesn't take migrated caps into account
function get_new_caps() {
    # echo "Getting new caps introduced in target release as compared to source release..."
    local source="$1"
    local target="$2"
    local array_source array_target extra_caps

    # Check for missing environment variables
    if [ -z "$source" ] || [ -z "$target" ]; then
        echo "ERROR: Missing required arguments"
        return 1
    fi

    # Split the elements into arrays
    IFS=" " read -ra array_source <<< "${source}"
    IFS=" " read -ra array_target <<< "${target}"

    # Find the extra elements in $target compared to $source
    extra_caps=()
    for cap in "${array_target[@]}"; do
        #shellcheck disable=SC2076
        if [[ ! " ${array_source[*]} " =~ " ${cap} " ]]; then
            extra_caps+=("$cap")
        fi
    done

    # Combine the extra elements into a space-separated string
    if (( ${#extra_caps[@]} != 0 )); then
        echo "${extra_caps[*]}"
    fi
    #echo "Expected implicitly enabled capabilities list is ${expected_implicit_caps}"
}

# compares two payloads for capabilities difference at manifest level
function extract_migrated_caps() {
    echo "Extracting migrated caps between 2 releases..."
    local source="$1"
    local target="$2"
    local source_dir target_dir source_cap_files

    # Check for missing environment variables
    if [ -z "$source" ] || [ -z "$target" ]; then
        echo "ERROR: Missing required arguments"
        return 1
    fi

    source_dir="/tmp/source"
    target_dir="/tmp/target"
    mkdir -p ${source_dir} ${target_dir}

    if ! extract_manifests "${source_dir}" "${source}" || ! extract_manifests "${target_dir}" "${target}"; then
        return 1
    fi

    source_cap_files=$(grep -rl "capability.openshift.io/name" ${source_dir})
    for source_file in ${source_cap_files}; do
        filename=$(basename "${source_file}")
        target_file="$target_dir/$filename"

        if [ -f "$target_file" ]; then
            source_cap=$(grep 'capability.openshift.io/name:' "$source_file" | cut -d ':' -f2 | tr -d '"' | sort | uniq )
            target_cap=$(grep 'capability.openshift.io/name:' "$target_file" | cut -d ':' -f2 | tr -d '"' | sort | uniq )

            if [ "$source_cap" != "$target_cap" ]; then
                echo "Migrated capability in $filename: $source_cap -> $target_cap"
                migrated_caps["$source_cap"]=$target_cap
            fi
        fi
    done
}

function check_cvo_cap() {

    local result=0
    local capability_set=$1
    local expected_status=$2
    local cvo_field=$3

    cvo_caps=$(oc get clusterversion version -o json | jq -rc "${cvo_field}")
    if [[ "${capability_set}" == "" ]] && [[ "${cvo_caps}" != "null" ]]; then
        echo "ERROR: ${expected_status} capability set is empty, but find capabilities ${cvo_caps} in cvo ${cvo_field}"
        result=1
    fi
    if [[ "${capability_set}" != "" ]]; then
        if [[ "${cvo_caps}" == "null" ]]; then
            echo "ERROR: ${expected_status} capability set are ${capability_set}, but it's empty in cvo ${cvo_field}"
            result=1
        else
            cvo_caps_str=$(echo $cvo_caps | tr -d '["]' | tr "," " " | xargs -n1 | sort -u | xargs)
            if [[ "${cvo_caps_str}" == "${capability_set}" ]]; then
                echo "INFO: ${expected_status} capabilities matches with cvo ${cvo_field}!"
                echo -e "cvo_caps: ${cvo_caps_str}\n${expected_status} capability set: ${capability_set}"
            else
                echo "ERROR: ${expected_status} capabilities does not match with cvo ${cvo_field}!"
                echo -e "cvo_caps: ${cvo_caps_str}\n${expected_status} capability set: ${capability_set}"
                echo "diff [cvo_caps] [${expected_status} capability set]"
                diff <( echo $cvo_caps_str | tr " " "\n" | sort | uniq) <( echo $capability_set | tr " " "\n" | sort | uniq )
                result=1
            fi
        fi
    fi

    return $result
} >&2

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "Unable to find kubeconfig under ${SHARED_DIR}!"
    exit 1
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

baselinecaps_from_cluster=$(oc get clusterversion version -ojson | jq -r '.spec.capabilities.baselineCapabilitySet')
if [[ -z "${baselinecaps_from_cluster}" || "${baselinecaps_from_cluster}" == "null" ]]; then
    echo "spec.capabilities.baselineCapabilitySet is not set or is null, skip the check!"
    exit 0
fi
echo "baselinecaps_from_cluster: ${baselinecaps_from_cluster}"

# shellcheck disable=SC2207
version_set=($(oc get clusterversion version -ojson | jq -r .status.history[].version))

# Mapping between optional capability and operators
# Need update when new operator marks as optional
declare -A caps_operator
caps_operator[baremetal]="baremetal"
caps_operator[marketplace]="marketplace"
caps_operator[openshift-samples]="openshift-samples"
caps_operator[CSISnapshot]="csi-snapshot-controller"
caps_operator[Console]="console"
caps_operator[Insights]="insights"
caps_operator[Storage]="storage"
caps_operator[NodeTuning]="node-tuning"
caps_operator[MachineAPI]="machine-api control-plane-machine-set cluster-autoscaler"
caps_operator[ImageRegistry]="image-registry"
caps_operator[OperatorLifecycleManager]="operator-lifecycle-manager operator-lifecycle-manager-catalog operator-lifecycle-manager-packageserver"
caps_operator[CloudCredential]="cloud-credential"

# Mapping between optional capability and resources
# Need update when new resource marks as optional
caps_resource_list="Build DeploymentConfig"
declare -A caps_resource
caps_resource[Build]="builds buildconfigs"
caps_resource[DeploymentConfig]="deploymentconfigs"

# Initialize the variables
declare -A migrated_caps=()
if ! extract_migrated_caps "${version_set[-1]}" "${version_set[0]}"; then
    echo "ERROR: extract_migrated_caps failed" && exit 1
fi

expected_enabled_caps=""
expected_implicit_caps=""
expected_disabled_caps=""

source_baseline_caps=$(get_caps_for_version_capset "${version_set[-1]}" "${baselinecaps_from_cluster}")
target_baseline_caps=$(get_caps_for_version_capset "${version_set[0]}" "${baselinecaps_from_cluster}")

source_known_caps=$(get_caps_for_version_capset "${version_set[-1]}" "vCurrent")
target_known_caps=$(get_caps_for_version_capset "${version_set[0]}" "vCurrent")

new_caps=$(get_new_caps "${source_known_caps}" "${target_known_caps}")

additionalcaps_from_cluster=$(oc get clusterversion version -ojson | jq -r 'if .spec.capabilities.additionalEnabledCapabilities then .spec.capabilities.additionalEnabledCapabilities[] else empty end')

echo -e "\nsource_baseline_caps is ${source_baseline_caps}\
\ntarget_baseline_caps is ${target_baseline_caps}\
\nsource_known_caps is ${source_known_caps}\ntarget_known_caps is ${target_known_caps}\
\nnew_caps is ${new_caps}\nadditionalcaps_from_cluster is ${additionalcaps_from_cluster}"

# vCurrent baseline set should grow new caps of target version explicitly after upgrade
if [[ "${baselinecaps_from_cluster}" == "vCurrent" ]]; then
    expected_enabled_caps="${additionalcaps_from_cluster} ${target_baseline_caps}"
fi

# v4.x baseline set should grow new caps in v4.x of target version explicitly after upgrade
# v4.x baseline set should grow new caps in target version implicitly
# v4.x baseline set should grow new caps implicitly after upgrade if cap migrates to a cap out of v4.x & additional caps of target version
if [[ "${baselinecaps_from_cluster}" == "v4."* ]]; then
    source_enabled_caps="${source_baseline_caps} ${additionalcaps_from_cluster}"
    target_enabled_caps="${target_baseline_caps} ${additionalcaps_from_cluster}"
    expected_enabled_caps="${target_enabled_caps}"
    
    expected_enabled_caps="${expected_enabled_caps} ${new_caps}"
    expected_implicit_caps="${expected_implicit_caps} ${new_caps}"

    if [ ${#migrated_caps[@]} -eq 0 ]; then
        echo "migrated_caps is empty."
    else
        echo "migrated_caps is not empty."
        for key in "${!migrated_caps[@]}"; do
            if [[ $source_enabled_caps == *$key* ]] && [[ $target_enabled_caps != *${migrated_caps[$key]}* ]]; then
                expected_enabled_caps="${expected_enabled_caps} ${migrated_caps[$key]}"
                expected_implicit_caps="${expected_implicit_caps} ${migrated_caps[$key]}"
            fi
        done
    fi
fi

# None baseline set should grow new caps of target version implicitly after upgrade
# None baseline set should grow new caps if caps migrate to someones that are not in additional caps
if [[ "${baselinecaps_from_cluster}" == "None" ]]; then
    expected_enabled_caps="${additionalcaps_from_cluster}"
    expected_enabled_caps="${expected_enabled_caps} ${new_caps}"
    expected_implicit_caps="${expected_implicit_caps} ${new_caps}"

    if [ ${#migrated_caps[@]} -eq 0 ]; then
        echo "migrated_caps is empty."
    else
        echo "migrated_caps is not empty."
        for key in "${!migrated_caps[@]}"; do
            if [[ ${additionalcaps_from_cluster} == *$key* ]] && [[ ${additionalcaps_from_cluster} != *${migrated_caps[$key]}* ]]; then
                expected_enabled_caps="${expected_enabled_caps} ${migrated_caps[$key]}"
                expected_implicit_caps="${expected_implicit_caps} ${migrated_caps[$key]}"
            fi
        done
    fi
fi

actual_implicit_caps=""
if ! get_actual_implicit_caps; then
    echo "ERROR: get_actual_implicit_caps failed" && exit 1
fi

actual_implicit_caps=$(echo ${actual_implicit_caps} | xargs -n1 | sort -u | xargs)
expected_implicit_caps=$(echo ${expected_implicit_caps} | xargs -n1 | sort -u | xargs)
expected_enabled_caps=$(echo ${expected_enabled_caps} | xargs -n1 | sort -u | xargs)
expected_disabled_caps="${target_known_caps}"
for cap in $expected_enabled_caps; do
    expected_disabled_caps=${expected_disabled_caps/$cap}
done
expected_disabled_caps=$(echo ${expected_disabled_caps} | xargs -n1 | sort -u | xargs)

echo -e "\nactual_implicit_caps is ${actual_implicit_caps}\
\nexpected_enabled_caps is ${expected_enabled_caps}\
\nexpected_implicit_caps is ${expected_implicit_caps}\
\nexpected_disabled_caps is ${expected_disabled_caps}"

# Overall check result
check_result=0

# Check if Implicitly enabled caps are correct
echo "------check .status.conditions.ImplicitlyEnabledCapabilities------"
echo -e "actual_implicit_caps: ${actual_implicit_caps}\nexpected_implicit_caps: ${expected_implicit_caps}"
if [[ "${actual_implicit_caps}" == "${expected_implicit_caps}" ]]; then
    echo "INFO: Actual implicitly enabled capabilities match expected implicitly enabled capabilities"   
else
    echo "ERROR: Actual implicitly enabled capabilities don't match expected implicitly enabled capabilities"
    check_result=1
fi

# Check if cvo status.capabilities correct
echo "------check cvo status capabilities check-----"
echo "===check .status.capabilities.enabledCapabilities"
check_cvo_cap "${expected_enabled_caps}" "enabled" ".status.capabilities.enabledCapabilities" || check_result=1

echo "===check .status.capabilities.knownCapabilities"
vcurrent_str=$(echo "${target_known_caps}" | xargs -n1 | sort -u | xargs)
check_cvo_cap "${vcurrent_str}" "known" ".status.capabilities.knownCapabilities" || check_result=1

echo "------cluster operators------"
co_content=$(mktemp)
oc get co | tee ${co_content}

# Check if the resources of enabled capabilities exist in the cluster
echo "------check enabled capabilities-----"
echo "enabled capability set: ${expected_enabled_caps}"
for cap in $expected_enabled_caps; do
    echo "check capability ${cap}"
    #shellcheck disable=SC2076
    if [[ " ${caps_resource_list} " =~ " ${cap} " ]]; then
        resource="${caps_resource[$cap]}"
        res_ret=0
        for r in ${resource}; do
            oc api-resources | grep ${r} || res_ret=1
        done
        if [[ ${res_ret} -eq 1 ]] ; then
            echo "ERROR: capability ${cap}: resources ${resource} -- not found!"
            check_result=1
        fi
        continue
    fi
    for op in ${caps_operator[$cap]}; do
        if [[ ! `grep -e "^${op} " ${co_content}` ]]; then
            echo "ERROR: capability ${cap}: operator ${op} -- not found!"
            check_result=1
        fi
    done
done

# Check if the resources of disabled capabilities not exist in the cluster
echo "------check disabled capabilities-----"
echo "disabled capability set: ${expected_disabled_caps}"
for cap in $expected_disabled_caps; do
    echo "check capability ${cap}"
    #shellcheck disable=SC2076
    if [[ " ${caps_resource_list} " =~ " ${cap} " ]]; then
        resource="${caps_resource[$cap]}"
        res_ret=0
        for r in ${resource}; do
            oc api-resources | grep ${r} || res_ret=1
        done
        if [[ ${res_ret} -eq 0 ]]; then
            echo "ERROR: capability ${cap}: resources ${resource} -- found!"
            check_result=1
        fi
        continue
    fi
    for op in ${caps_operator[$cap]}; do
        if [[ `grep -e "^${op} " ${co_content}` ]]; then
            echo "ERROR: capability ${cap}: operator ${op} -- found"
            check_result=1
        fi
    done
done

if [[ ${check_result} == 1 ]]; then
    echo -e "\nCapability check result -- FAILED, please check above details!"
    exit 1
else
    echo -e "\nCapability check result -- PASSED!"
fi
