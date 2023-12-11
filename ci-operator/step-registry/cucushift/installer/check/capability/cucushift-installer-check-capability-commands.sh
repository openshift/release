#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

baselinecaps_from_config=$(yq-go r "${SHARED_DIR}/install-config.yaml" "capabilities.baselineCapabilitySet")
if [[ "${baselinecaps_from_config}" == "" ]]; then
    echo "Field capabilities.baselineCapabilitySet in install-config is not set, skip the check!"
    exit 0
fi
echo "baselinecaps_from_config: ${baselinecaps_from_config}"

function cvoCapabilityCheck() {

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

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

# Setting proxy only if you need to communicate with installed cluster
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Mapping between optional capability and operators
# Need to be updated when new operator marks as optional
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
# Need to be updated when new resource marks as optional
caps_resource_list="Build DeploymentConfig"
declare -A caps_resource
caps_resource[Build]="build"
caps_resource[DeploymentConfig]="deploymentconfig"

v411="baremetal marketplace openshift-samples"
# shellcheck disable=SC2034
v412=" ${v411} Console Insights Storage CSISnapshot"
v413=" ${v412} NodeTuning"
v414=" ${v413} MachineAPI Build DeploymentConfig ImageRegistry"
v415=" ${v414} OperatorLifecycleManager CloudCredential"
latest_defined="v415"
always_default="${!latest_defined}"

# Determine vCurrent
declare "v${ocp_major_version}${ocp_minor_version}"
v_current_version="v${ocp_major_version}${ocp_minor_version}"

if [[ ${!v_current_version:-} == "" ]]; then
  echo "vCurrent: No default value for ${v_current_version}, use default value from ${latest_defined}: ${!latest_defined}"
  vCurrent=${always_default}
else
  echo "vCurrent: Use exsting value from ${v_current_version}: ${!v_current_version}"
  vCurrent=${!v_current_version}
fi
echo "vCurrent set: $vCurrent"

enabled_capability_set=""
case ${baselinecaps_from_config} in
"None")
  ;;
"v4.11")
  enabled_capability_set="${v411}"
  (( ocp_minor_version >=14 && ocp_major_version == 4 )) && enabled_capability_set="${enabled_capability_set} MachineAPI"
  ;;
"v4.12")
  enabled_capability_set="${v412}"
  (( ocp_minor_version >=14 && ocp_major_version == 4 )) && enabled_capability_set="${enabled_capability_set} MachineAPI"
  ;;
"v4.13")
  enabled_capability_set="${v413}"
  (( ocp_minor_version >=14 && ocp_major_version == 4 )) && enabled_capability_set="${enabled_capability_set} MachineAPI"
  ;;
"v4.14")
  enabled_capability_set="${v414}"
  ;;
"v4.15")
  enabled_capability_set="${v415}"
  ;;
"vCurrent")
  enabled_capability_set="${vCurrent}"
  ;;
*)
  enabled_capability_set="${always_default}"
  ;;
esac

additional_caps_from_config=$(yq-go r "${SHARED_DIR}/install-config.yaml" "capabilities.additionalEnabledCapabilities[*]" | xargs -n1 | sort -u | xargs)
if [[ "${additional_caps_from_config}" != "" ]]; then
    enabled_capability_set="${enabled_capability_set} ${additional_caps_from_config}"
fi
enabled_capability_set=$(echo ${enabled_capability_set} | xargs -n1 | sort -u | xargs)
disabled_capability_set="${vCurrent}"
for cap in $enabled_capability_set; do
    disabled_capability_set=${disabled_capability_set/$cap}
done

echo "------cluster operators------"
co_content=$(mktemp)
oc get co | tee ${co_content}

check_result=0
# Enabled capabilities check
echo "------check enabled capabilities-----"
echo "enabled capability set: ${enabled_capability_set}"
for cap in $enabled_capability_set; do
    echo "check capability ${cap}"
    #shellcheck disable=SC2076
    if [[ " ${caps_resource_list} " =~ " ${cap} " ]]; then
        resource="${caps_resource[$cap]}"
        res_ret=0
        oc api-resources | grep ${resource} || res_ret=1
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

# Disabled capabilities check
echo "------check disabled capabilities-----"
echo "disabled capability set: ${disabled_capability_set}"
for cap in $disabled_capability_set; do
    echo "check capability ${cap}"
    #shellcheck disable=SC2076
    if [[ " ${caps_resource_list} " =~ " ${cap} " ]]; then
        resource="${caps_resource[$cap]}"
        res_ret=0
        oc api-resources | grep ${resource} || res_ret=1
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

# cvo spec check
# Check baselineCapabilitySet in cvo spec
echo "------check baselineCapabilitySet setting in cvo spec-----"
baselinecaps_from_cvo=$(oc get clusterversion version -ojson | jq -r ".spec.capabilities.baselineCapabilitySet")
if [[ "${baselinecaps_from_cvo}" != "${baselinecaps_from_config}" ]]; then
    echo "ERROR: baselineCapabilitySet in install-config.yaml does not match with setting in cvo spec!"
    echo -e "baselineCapabilitySet in install-config.yaml: ${baselinecaps_from_config}\nbaselineCapabilitySet in cvo spec: ${baselinecaps_from_cvo}"
    check_result=1
else
    echo "INFO: baselineCapabilitySet in install-config.yaml matches with setting in cvo spec!"
fi
# Check additionalEnabledCapabilities in cvo spec
echo "------check additionalEnabledCapabilities setting in cvo spec-----"
addtional_caps_from_cvo=$(oc get clusterversion version -oyaml | yq-go r - "spec.capabilities.additionalEnabledCapabilities[*]" | xargs -n1 | sort -u | xargs)
if [[ "${addtional_caps_from_cvo}" != "${additional_caps_from_config}" ]]; then
    echo "ERROR: additionalEnabledCapabilities in install-config.yaml does not match with setting in cvo spec!"
    echo -e "additionalEnabledCapabilities in install-config.yaml: ${additional_caps_from_config}\nadditionalEnabledCapabilities in cvo spec: ${addtional_caps_from_cvo}"
    check_result=1
else
    echo "INFO: additionalEnabledCapabilities in install-config.yaml matches with setting in cvo spec!"
fi

# cvo status capability check
echo "------check cvo status capabilities check-----"
echo "===check .status.capabilities.enabledCapabilities"
cvoCapabilityCheck "${enabled_capability_set}" "enabled" ".status.capabilities.enabledCapabilities" || check_result=1

echo "===check .status.capabilities.knownCapabilities"
vcurrent_str=$(echo "${vCurrent}" | xargs -n1 | sort -u | xargs)
cvoCapabilityCheck "${vcurrent_str}" "known" ".status.capabilities.knownCapabilities" || check_result=1

if [[ ${check_result} == 1 ]]; then
    echo -e "\nCapability check result -- FAILED, please check above details!"
    exit 1
else
    echo -e "\nCapability check result -- PASSED!"
fi
