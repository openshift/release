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

function check_invalid_instance_type()
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

patch_file=$(mktemp)
#---------------------------------------
# Check vCPUsAvailable is at least 4 for control plane node
#---------------------------------------
cat > ${patch_file} << EOF
controlPlane:
  platform:
    azure:
      type: Standard_DC2s_v3
platform:
  azure:
    region: eastus
EOF
echo "**********Check an invalid instance type (less than 4 vCPUsAvailable) for control plane with the proper error message**********"
error_key_words='controlPlane.platform.azure.type: Invalid value: \"Standard_DC2s_v3\": instance type does not meet minimum resource requirements of 4 vCPUsAvailable'
check_invalid_instance_type "${patch_file}" "${error_key_words}" || check_result=1

#---------------------------------------
# Check MemoryGB is at least 16G for control plane node
#---------------------------------------
cat > ${patch_file} << EOF
controlPlane:
  platform:
    azure:
      type: Standard_DS3_v2
platform:
  azure:
    region: eastus
EOF
echo "**********Check an invalid instance type (less than 16G MemoryGB) for control plane with the proper error message**********"
error_key_words='controlPlane.platform.azure.type: Invalid value: \"Standard_DS3_v2\": instance type does not meet minimum resource requirements of 16 GB Memory'
check_invalid_instance_type "${patch_file}" "${error_key_words}" || check_result=1

#---------------------------------------
# Check vCPUsAvailable is at least 2 for compute
#---------------------------------------
cat > ${patch_file} << EOF
compute:
- platform:
    azure:
      type: Standard_DC1s_v3
platform:
  azure:
    region: eastus
EOF
echo "**********Check an invalid instance type (less than 2 vCPUsAvailable) for compute with the proper error message**********"
error_key_words='compute[0].platform.azure.type: Invalid value: \"Standard_DC1s_v3\": instance type does not meet minimum resource requirements of 2 vCPUsAvailable'
check_invalid_instance_type "${patch_file}" "${error_key_words}" || check_result=1

#---------------------------------------
# Check MemoryGB is at least 8G for compute
#---------------------------------------
cat > ${patch_file} << EOF
compute:
- platform:
    azure:
      type: Standard_B2s
platform:
  azure:
    region: eastus
EOF
echo "**********Check an invalid instance type (less than 8G MemoryGB) for compute with the proper error message**********"
error_key_words='compute[0].platform.azure.type: Invalid value: \"Standard_B2s\": instance type does not meet minimum resource requirements of 8 GB Memory'
check_invalid_instance_type "${patch_file}" "${error_key_words}" || check_result=1

#---------------------------------------
# Check that decimal MemoryGB value has correct check
# Standard_D1_v2 - MemoryGB:3.5
#---------------------------------------
cat > ${patch_file} << EOF
compute:
- platform:
    azure:
      type: Standard_D1_v2
platform:
  azure:
    region: eastus
EOF
echo "**********Check an invalid instance type (less than 8G MemoryGB and value is decimal) for compute with the proper error message**********"
error_key_words='compute[0].platform.azure.type: Invalid value: \"Standard_D1_v2\": instance type does not meet minimum resource requirements of 8 GB Memory'
check_invalid_instance_type "${patch_file}" "${error_key_words}" || check_result=1

#---------------------------------------
# Check that installer uses vCPUsAvailable, but not vCPUs to do pre-check
# Standard_E8-2s_v4 - vCPUsAvailable:2 vCPUs:8
#---------------------------------------
cat > ${patch_file} << EOF
controlPlane:
  platform:
    azure:
      type: Standard_E8-2s_v4
platform:
  azure:
    region: eastus
EOF
echo "**********Check an invalid instance type (installer uses vCPUsAvailable but not vCPUs to do pre-check) for control node with the proper error message**********"
error_key_words='controlPlane.platform.azure.type: Invalid value: \"Standard_E8-2s_v4\": instance type does not meet minimum resource requirements of 4 vCPUsAvailable'
check_invalid_instance_type "${patch_file}" "${error_key_words}" || check_result=1

exit ${check_result}
