#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

baselinecaps_from_config=$(yq-go r "${SHARED_DIR}/install-config.yaml" "capabilities.baselineCapabilitySet")
if [[ "${baselinecaps_from_config}" == "" ]]; then
    echo "This step requires field capabilities.baselineCapabilitySet in install-config to be set!"
    exit 1
fi

if [[ "${ADDITIONAL_ENABLED_CAPABILITIES}" != "" ]]; then
   echo "ENV 'ADDITIONAL_ENABLED_CAPABILITIES' is set, this step is not required!"
   exit 0
fi

# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST,
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with
# user specified image pullspec, to avoid auth error when accessing it, always use build farm
# registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
    tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
    echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
    tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
    echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
    TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
    TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(oc adm release info ${TESTING_RELEASE_IMAGE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

v411="baremetal marketplace openshift-samples"
v412=" ${v411} Console Insights Storage CSISnapshot"
v413=" ${v412} NodeTuning"
# shellcheck disable=SC2034
v414=" ${v413} MachineAPI Build DeploymentConfig ImageRegistry"
# shellcheck disable=SC2034
v415=" ${v414} OperatorLifecycleManager CloudCredential"
latest_version="v415"

# define capability dependency
declare -A dependency_caps
dependency_caps["marketplace"]="OperatorLifecycleManager"

declare "v${ocp_major_version}${ocp_minor_version}"
v_current_version="v${ocp_major_version}${ocp_minor_version}"

if [[ ${!v_current_version:-} == "" ]]; then
  echo "vCurrent: No default value for ${v_current_version}, use default value from ${latest_version}"
  vcurrent_capabilities=${!latest_version}
else
  echo "vCurrent: Use exsting value from ${v_current_version}: ${!v_current_version}"
  vcurrent_capabilities=${!v_current_version}
fi

#Randomly select one capability to be disabled
# shellcheck disable=SC2206
vcurrent_capabilities_array=(${vcurrent_capabilities})
echo "vcurrent_capabilities: ${vcurrent_capabilities_array[*]}"

enabled_capabilities=${vcurrent_capabilities}
additional_caps_from_config=$(yq-go r "${SHARED_DIR}/install-config.yaml" "capabilities.additionalEnabledCapabilities[*]")
selected_capability=""
while [[ -z "${selected_capability}" ]]; do
    selected_capability_index=$((RANDOM % ${#vcurrent_capabilities_array[@]}))
    selected_capability="${vcurrent_capabilities_array[$selected_capability_index]}"
    # If selected to be disabled cap has already been set to additionalEnabledCapabilities in install-config, should not be disabled
    #shellcheck disable=SC2076
    if [[ " ${additional_caps_from_config} " =~ " ${selected_capability} " ]]; then
        echo "WARNING: selected cap ${selected_capability} is already configured in field additionalEnabledCapabilities in install-config, unable to be disabled!"
        selected_capability=""
        continue
    fi
    case "${selected_capability}" in
    "MachineAPI")
        echo "WARNING: MachineAPI is selected, but it requires on IPI, could not be disabled!"
        selected_capability=""
        ;;
    # To be updated once OCP 4.16 is released
    "CloudCredential")
        if [[ "${CLUSTER_TYPE}" =~ ^packet.*$|^equinix.*$ ]]; then
            enabled_capabilities=${enabled_capabilities/${selected_capability}}
        else
            echo "WARNING: non-BareMetal platforms require CCO for OCP 4.15, could not be disabled!"
            selected_capability=""
        fi
        ;;
    *)
        enabled_capabilities=${enabled_capabilities/${selected_capability}}
        for key in "${!dependency_caps[@]}"; do
            if [[ "${selected_capability}" == "${dependency_caps[$key]}" ]]; then
                echo "capability ${key} depends on Capability ${dependency_caps[$key]}, so disable ${key} along with ${dependency_caps[$key]}"
                enabled_capabilities=${enabled_capabilities/"$key"}
            fi
        done
    esac
done
echo "Selected capability to be disabled: ${selected_capability}"

# Append additionalEnabledCapabilities if any already configured in install-config
enabled_capabilities=$(echo "${enabled_capabilities} ${additional_caps_from_config}" | xargs -n1 | sort -u | xargs)
echo "enabled_capabilities: ${enabled_capabilities}"

# apply patch to install-config
CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-capability.yaml.path"
cat > "${PATCH}" << EOF
capabilities:
  additionalEnabledCapabilities:
EOF
for item in ${enabled_capabilities}; do
    cat >> "${PATCH}" << EOF
  - ${item}
EOF
done

yq-go m -x -i "${CONFIG}" "${PATCH}"
cat ${PATCH}
