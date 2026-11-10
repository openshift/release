#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

function check_non_emtpy_rg()
{
    local patch_file=$1 expected_error=$2 ret=0

    echo -e "DEBUG: patch file \n-----"
    cat "${patch_file}"
    install_dir=$(mktemp -d)
    cat "${INSTALL_CONFIG}" > ${install_dir}/install-config.yaml
    yq-go m -x -i "${install_dir}/install-config.yaml" "${patch_file}"
    openshift-install create cluster --dir ${install_dir} || true

    if grep -qF "${expected_error}" "${install_dir}/.openshift_install.log"; then
        echo "INFO: get expected error, check passed!"
    else
        echo "ERROR: could not get expected error, check failed! expected error: ${expected_error}"
        ret=1
    fi

    rm -rf ${install_dir}
    return ${ret}
}

check_result=0
INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
patch_file=$(mktemp)
rg_file="${SHARED_DIR}/resourcegroup_sa"
if [ -f "${rg_file}" ]; then
    RESOURCE_GROUP=$(cat "${rg_file}")
else
    echo "Did not find an provisoned resource group"
    exit 1
fi
cat > ${patch_file} << EOF
platform:
  azure:
    resourceGroupName: ${RESOURCE_GROUP}
EOF

echo "**********Check installation in non-empty resource group fails with the proper error message**********"
error_key_words="platform.azure.resourceGroupName: Invalid value: \\\"${RESOURCE_GROUP}\\\": resource group must be empty but it has"
check_non_emtpy_rg "${patch_file}" "${error_key_words}" || check_result=1

exit ${check_result}
