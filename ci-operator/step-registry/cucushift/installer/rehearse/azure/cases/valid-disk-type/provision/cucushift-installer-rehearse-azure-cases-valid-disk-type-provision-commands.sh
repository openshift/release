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

function check_invalid_disk_type()
{
    local patch_file=$1 expected_error=$2 ret=0

    echo -e "DEBUG: patch file \n-----"
    cat "${patch_file}"
    install_dir=$(mktemp -d)
    cat "${INSTALL_CONFIG}" > ${install_dir}/install-config.yaml
    yq-go m -x -i "${install_dir}/install-config.yaml" "${patch_file}"
    openshift-install create manifests --dir ${install_dir} || true

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

#Verified that an incompatible value (Standard_LRS) controlPlane disk type configuration fails with the proper error message
patch_file=$(mktemp)
cat > ${patch_file} << EOF
controlPlane:
  platform:
    azure:
      osDisk:
        diskType: Standard_LRS
EOF

echo "**********Check an incompatible value (Standard_LRS) controlPlane disk type configuration fails with the proper error message**********"
error_key_words='controlPlane.platform.azure.diskType: Unsupported value: \"Standard_LRS\": supported values: \"Premium_LRS\", \"StandardSSD_LRS\"'
check_invalid_disk_type "${patch_file}" "${error_key_words}" || check_result=1

#Verified that an unsupported value for diskType also fails with a proper error message
cat > ${patch_file} << EOF
controlPlane:
  platform:
    azure:
      osDisk:
        diskType: Standard_LEET
EOF

echo -e "\n**********Check an unsupported value for diskType also fails with a proper error message**********"
error_key_words='controlPlane.platform.azure.diskType: Unsupported value: \"Standard_LEET\": supported values: \"Premium_LRS\", \"StandardSSD_LRS\"'
check_invalid_disk_type "${patch_file}" "${error_key_words}" || check_result=1

#Verified that an incompatible value (Standard_LRS) defaultMachinePlatform disk type configuration fails with the proper error message
cat > ${patch_file} << EOF
platform:
  azure:
    defaultMachinePlatform:
      osDisk:
        diskType: Standard_LRS
EOF

echo -e "\n**********Check an incompatible value (Standard_LRS) defaultMachinePlatform disk type configuration fails with the proper error message**********"
error_key_words='platform.azure.defaultMachinePlatform.diskType: Unsupported value: \"Standard_LRS\": supported values: \"Premium_LRS\", \"StandardSSD_LRS\"'
check_invalid_disk_type "${patch_file}" "${error_key_words}" || check_result=1

#Verified that an unsupported value for diskType under defaultMachinePlatform also fails with a proper error message
cat > ${patch_file} << EOF
platform:
  azure:
    defaultMachinePlatform:
      osDisk:
        diskType: Standard_LEET
EOF

echo -e "\n**********Check an unsupported value for diskType under defaultMachinePlatform also fails with a proper error message**********"
error_key_words='platform.azure.defaultMachinePlatform.diskType: Unsupported value: \"Standard_LEET\": supported values: \"Premium_LRS\", \"StandardSSD_LRS\"'
check_invalid_disk_type "${patch_file}" "${error_key_words}" || check_result=1

#Verified that an unsupported value for diskType under compute also fails with a proper error message
cat > ${patch_file} << EOF
compute:
- platform:
    azure:
      osDisk:
        diskType: Standard_LEET
EOF

echo -e "\n**********Check an unsupported value for diskType under compute also fails with a proper error message**********"
error_key_words='compute[0].platform.azure.diskType: Unsupported value: \"Standard_LEET\": supported values: \"Premium_LRS\", \"StandardSSD_LRS\", \"Standard_LRS\"'
check_invalid_disk_type "${patch_file}" "${error_key_words}" || check_result=1

#Verified that given instance type without capability PremiumIO fails with a proper error message when Azure disktype is Premium_LRS (default value)
cat > ${patch_file} << EOF
controlPlane:
  platform:
    azure: {}
compute:
- platform:
    azure: {}
platform:
  azure:
    defaultMachinePlatform:
      type: Standard_D32a_v4
EOF

echo -e "\n**********Check given instance type without capability PremiumIO fails with a proper error message when Azure disktype is Premium_LRS (default value)**********"
error_key_words='controlPlane.platform.azure.osDisk.diskType: Invalid value: \"Premium_LRS\": PremiumIO not supported for instance type Standard_D32a_v4, compute[0].platform.azure.osDisk.diskType: Invalid value: \"Premium_LRS\": PremiumIO not supported for instance type Standard_D32a_v4'
check_invalid_disk_type "${patch_file}" "${error_key_words}" || check_result=1

exit ${check_result}
