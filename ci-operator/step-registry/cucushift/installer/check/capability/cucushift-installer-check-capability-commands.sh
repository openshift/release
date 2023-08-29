#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${BASELINE_CAPABILITY_SET}" == "" ]]; then
  echo "This step is not required when BASELINE_CAPABILITY_SET is not set"
  exit 0
fi

function getVersion() {
  local release_image=""
  if [ -n "${RELEASE_IMAGE_INITIAL-}" ]; then
    release_image=${RELEASE_IMAGE_INITIAL}
  elif [ -n "${RELEASE_IMAGE_LATEST-}" ]; then
    release_image=${RELEASE_IMAGE_LATEST}
  fi

  local version=""
  if [ ${release_image} != "" ]; then
    version=$(oc adm release info ${release_image} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
  fi
  echo "${version}"
}

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

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(getVersion)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
echo "OCP Version: $ocp_version"


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

# Mapping between optional capability and resources
declare -A caps_resource
caps_resource[Build]="build.build.openshift.io"
caps_resource[DeploymentConfig]="dc"

v411="baremetal marketplace openshift-samples"
# shellcheck disable=SC2034
v412=" ${v411} Console Insights Storage CSISnapshot"
v413=" ${v412} NodeTuning"
v414=" ${v413} MachineAPI Build DeploymentConfig ImageRegistry"
latest_defined="v414"
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
case ${BASELINE_CAPABILITY_SET} in
"None")
  ;;
"v4.11")
  enabled_capability_set="${v411}"
  ;;
"v4.12")
  enabled_capability_set="${v412}"
  ;;
"v4.13")
  enabled_capability_set="${v413}"
  ;;
"v4.14")
  enabled_capability_set="${v414}"
  ;;
"vCurrent")
  enabled_capability_set="${vCurrent}"
  ;;
*)
  enabled_capability_set="${always_default}"
  ;;
esac

if [[ "${ADDITIONAL_ENABLED_CAPABILITIES}" != "" ]]; then
    enabled_capability_set="${enabled_capability_set} ${ADDITIONAL_ENABLED_CAPABILITIES}"
fi

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
    if [[ "${cap}" == "Build" ]] || [[ "${cap}" == "DeploymentConfig" ]]; then
        resource="${caps_resource[$cap]}"
        [[ "$(oc get ${resource} -A)" -ne 0 ]] && echo "ERROR: capability ${cap}: resources ${resource} -- not found!" && check_result=1
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
    if [[ "${cap}" == "Build" ]] || [[ "${cap}" == "DeploymentConfig" ]]; then
        resource="${caps_resource[$cap]}"
        [[ "$(oc get ${resource} -A)" -eq 0 ]] && echo "ERROR: capability ${cap}: resources ${resource} -- found!" && check_result=1
        continue
    fi
    for op in ${caps_operator[$cap]}; do
        if [[ `grep -e "^${op} " ${co_content}` ]]; then
            echo "ERROR: capability ${cap}: operator ${op} -- found"
            check_result=1
        fi
    done
done

# cvo status capability check
echo "------check cvo status capabilities check-----"
echo "===check .status.capabilities.enabledCapabilities"
enabled_capability_set=$(echo ${enabled_capability_set} | xargs -n1 | sort -u | xargs)
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
