#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

# define baselineCapabilitySet valid value on each version
v411_set="vCurrent v4.11"
v412_set="${v411_set} v4.12"
v413_set="${v412_set} v4.13"
v414_set="${v413_set} v4.14"
v415_set="${v414_set} v4.15"
v416_set="${v415_set} v4.16"
v417_set="${v416_set} v4.17"
# shellcheck disable=SC2034
v418_set="${v417_set} v4.18"
latest_version_set="v418_set"

# the content of each capset
v411="baremetal marketplace openshift-samples"
(( ocp_minor_version > 13 )) && v411="${v411} MachineAPI"
v412=" ${v411} Console Insights Storage CSISnapshot"
v413=" ${v412} NodeTuning"
v414=" ${v413} Build DeploymentConfig ImageRegistry"
v415=" ${v414} OperatorLifecycleManager CloudCredential"
v416=" ${v415} CloudControllerManager Ingress"
v417=" ${v416}"
# shellcheck disable=SC2034
v418=" ${v417} OperatorLifecycleManagerV1"
latest_version="v418"

# define capability dependency
declare -A dependency_caps
dependency_caps["marketplace"]="OperatorLifecycleManager"

declare "v${ocp_major_version}${ocp_minor_version}_set"
declare "v${ocp_major_version}${ocp_minor_version}"
v_current_version="v${ocp_major_version}${ocp_minor_version}"
v_current_version_set="v${ocp_major_version}${ocp_minor_version}_set"

if [[ ${!v_current_version_set:-} == "" ]]; then
  echo "vCurrent: No default value for ${v_current_version_set}, use default value from ${latest_version_set}"
  v_current_set=${!latest_version_set}
  v_current=${!latest_version}
else
  echo "vCurrent: Use exsting value from ${v_current_version_set}: ${!v_current_version_set}"
  v_current_set=${!v_current_version_set}
  v_current=${!v_current_version}
fi

# shellcheck disable=SC2206
baseline_caps_set_array=(${v_current_set})

#select one cap set randomly
echo "baselineCapabilitySet: ${baseline_caps_set_array[*]}"
selected_cap_set_index=$((RANDOM % ${#baseline_caps_set_array[@]}))
selected_cap_set="${baseline_caps_set_array[$selected_cap_set_index]}"
echo "Selected baseline capability set: ${selected_cap_set}"
echo "vcurrent version is ${v_current_version}"

# apply patch to install-config
CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-capability-baseline.yaml.path"
cat > "${PATCH}" << EOF
capabilities:
  baselineCapabilitySet: ${selected_cap_set}
EOF

#To enable required capablities whatever baselineCapabilitySet setting
additional_caps=""
if [[ "${ADDITIONAL_ENABLED_CAPABILITIES}" != "" ]]; then
    echo "Enable required capabilities: ${ADDITIONAL_ENABLED_CAPABILITIES}"
    additional_caps="${ADDITIONAL_ENABLED_CAPABILITIES}"
fi

# Capablities dependency
if [[ "${selected_cap_set}" != "vCurrent" ]]; then
    # cap marketplace must be enabled along with OperatorLifecycleManager
    selected_set=${selected_cap_set//.}
    for key in "${!dependency_caps[@]}"; do
        #shellcheck disable=SC2076
        if [[ " ${!selected_set} " =~ " ${key} " ]] && [[ ! " ${!selected_set} " =~ " ${dependency_caps[$key]} " ]] && [[ " ${v_current} " =~ " ${dependency_caps[$key]} " ]]; then
            echo "capability ${key} in capset '${selected_cap_set}' requires ${dependency_caps[$key]}, enabling ${dependency_caps[$key]}"
            additional_caps="${additional_caps} ${dependency_caps[$key]}"
        fi
    done
fi

if [[ -n "${additional_caps}" ]]; then
    cat >> "${PATCH}" << EOF
  additionalEnabledCapabilities:
EOF
    for item in ${additional_caps}; do
        cat >> "${PATCH}" << EOF
    - ${item}
EOF
    done
fi

yq-go m -x -i "${CONFIG}" "${PATCH}"
cat ${PATCH}
