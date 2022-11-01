#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
# ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
# ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
rm /tmp/pull-secret

echo "OCP Version: $ocp_version"

v411="baremetal marketplace openshift-samples"
v412="baremetal marketplace openshift-samples Console Insights Storage CSISnapshot"
vCurrent=""

case ${ocp_version} in
"4.11")
  vCurrent="${v411}"
  ;;
"4.12")
  vCurrent="${v412}"
  ;;
*)
  ;;
esac

echo "vCurrent set: $vCurrent"

# Base Capability
base_operators=""
case ${BASELINE_CAPABILITY_SET} in
"None")
  ;;
"v4.11")
  base_operators="${v411}"
  ;;
"v4.12")
  base_operators="${v412}"
  ;;
"vCurrent")
  base_operators="${vCurrent}"
  ;;
*)
  base_operators="${vCurrent}" # include all operators by default
  ;;
esac

echo "Baseline Capability Set: $base_operators"

# Base Capability + Additional Capability
all_caps=$(echo "$base_operators $ADDITIONAL_ENABLED_CAPABILITY_SET" | xargs -n1 | sort -u | xargs)
echo "Enabled Capability Set: $all_caps"

if [[ "${ocp_version}" == "4.12" ]]; then
    if [[ ! "${all_caps}" =~ "Storage" ]]; then
        namespace="openshift-cluster-csi-drivers"
        remove_secrets "${SHARED_DIR}" "${namespace}" || exit 1
    fi
fi

exit 0
