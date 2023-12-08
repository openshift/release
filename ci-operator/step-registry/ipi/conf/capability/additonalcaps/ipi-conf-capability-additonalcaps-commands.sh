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
selected_capability_index=$((RANDOM % ${#vcurrent_capabilities_array[@]}))
selected_capability="${vcurrent_capabilities_array[$selected_capability_index]}"
echo "Selected capability to be disabled: ${selected_capability}"

enabled_capabilities=${vcurrent_capabilities}
case "${selected_capability}" in
"MachineAPI")
    echo "WARNING: MachineAPI is selected, but it requires on IPI, so no capability to be disabled!"
    ;;
# To be updated once OCP 4.16 is released
"CloudCredential")
    if [[ "${CLUSTER_TYPE}" =~ ^packet.*$|^equinix.*$ ]]; then
        enabled_capabilities=${enabled_capabilities/${selected_capability}}
    else
        echo "WARNING: non-BareMetal platforms require CCO for OCP 4.15, so no capability to be disabled!"
    fi
    ;;
# Disable marketplace if OperatorLifecycleManager is selected to bo disabled
"OperatorLifecycleManager")
    echo "Capability 'marketplace' depends on Capability 'OperatorLifecycleManager', so disable marketplace along with OperatorLifecycleManager"
    enabled_capabilities=${enabled_capabilities/${selected_capability}}
    enabled_capabilities=${enabled_capabilities/"marketplace"}
    ;;
*)
    enabled_capabilities=${enabled_capabilities/${selected_capability}}
esac

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
