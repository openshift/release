#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${EXTRACT_MANIFEST_INCLUDED}" == "true" ]]; then
  echo "This step is not required when EXTRACT_MANIFEST_INCLUDED is set to true"
  exit 0
fi

if [[ "${BASELINE_CAPABILITY_SET}" == "" ]]; then
  echo "This step is not required when BASELINE_CAPABILITY_SET is not set"
  exit 0
fi

function remove_secrets()
{
    local path="$1"
    local sec_namespace="$2"
    if [ ! -e "${path}" ]; then
        echo "[ERROR] ${path} does not exist"
        return 2
    fi
    pushd "${path}"
    for i in *.yaml; do
        res_kind=$(yq-go r "${i}" 'kind')
        res_namespace=$(yq-go r "${i}" 'metadata.namespace')
        if [[ "${res_kind}" == "Secret" ]] && [[ "${res_namespace}" == "${sec_namespace}" ]]; then
            echo "[WARN] Remove file ${i} which matches \"${sec_namespace}\""
            rm -f "${i}"
            [ $? -ne 0 ] && echo "[ERROR] error remove file ${i}" && return 1
        fi
    done
    popd
    return 0
}

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret

# shellcheck disable=SC2153
REPO=$(oc -n ${NAMESPACE} get is release -o json | jq -r '.status.publicDockerImageRepository')
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${REPO}:latest --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
rm /tmp/pull-secret

echo "OCP Version: $ocp_version"

if (( ocp_minor_version <=10 && ocp_major_version == 4 )) || (( ocp_major_version < 4 )); then
  echo "This step is not required for ${ocp_version}, exit now"
  exit 0
fi

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

# Determine BASELINE_CAPABILITY_SET

enabled_operators=""
case ${BASELINE_CAPABILITY_SET} in
"None")
  ;;
"v4.11")
  enabled_operators="${v411}"
  ;;
"v4.12")
  enabled_operators="${v412}"
  ;;
"v4.13")
  enabled_operators="${v413}"
  ;;
"v4.14")
  enabled_operators="${v414}"
  ;;
"v4.15")
  enabled_operators="${v415}"
  ;;
"vCurrent")
  enabled_operators="${vCurrent}"
  ;;
*)
  enabled_operators="${always_default}"
  ;;
esac


# Base Capability + Additional Capability

echo "Baseline Capability Set: $enabled_operators"
echo "Additional Capability Set: $ADDITIONAL_ENABLED_CAPABILITIES"
enabled_operators=$(echo "$enabled_operators $ADDITIONAL_ENABLED_CAPABILITIES" | xargs -n1 | sort -u | xargs)
echo "Enabled Capability Set: $enabled_operators"

# Remove openshift-cluster-csi-drivers, >= 4.12
if (( ocp_minor_version >=12 && ocp_major_version == 4 )); then
  if [[ ! "${enabled_operators}" =~ "Storage" ]]; then
      namespace="openshift-cluster-csi-drivers"
      remove_secrets "${SHARED_DIR}" "${namespace}" || exit 1
  fi
fi

# Remove openshift-machine-api/openshift-image-registry secret, >= 4.14
if (( ocp_minor_version >=14 && ocp_major_version == 4 )); then
  if [[ ! "${enabled_operators}" =~ "MachineAPI" ]]; then 
      namespace="openshift-machine-api"
      remove_secrets "${SHARED_DIR}" "${namespace}" || exit 1
  fi

  if [[ ! "${enabled_operators}" =~ "ImageRegistry" ]]; then
      namespace="openshift-image-registry"
      remove_secrets "${SHARED_DIR}" "${namespace}" || exit 1
  fi
fi

exit 0
