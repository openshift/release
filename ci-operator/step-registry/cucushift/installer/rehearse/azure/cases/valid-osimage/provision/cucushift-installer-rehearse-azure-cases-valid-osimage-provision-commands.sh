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

function check_invalid_fields()
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
#Verify osImage from one ARO free image with purchase plan fails with the proper error message"
cat > ${patch_file} << EOF
controlPlane:
  platform:
    azure:
      osImage:
        plan: WithPurchasePlan
        offer: aro4
        publisher: azureopenshift
        sku: aro_417
        version: 417.94.20240701
EOF
echo "**********Check osImage from one ARO free image with purchase plan fails with the proper error message**********"
error_key_words='controlPlane.platform.azure.osImage: Invalid value: azure.OSImage{Plan:\"WithPurchasePlan\", Publisher:\"azureopenshift\", Offer:\"aro4\", SKU:\"aro_417\", Version:\"417.94.20240701\"}: image has no license terms. Set Plan to \"NoPurchasePlan\" to continue'
check_invalid_fields "${patch_file}" "${error_key_words}" || check_result=1

#Verify osImage from Gen1 image, while vm type only supports Gen2
cat > ${patch_file} << EOF
controlPlane:
  platform:
    azure:
      osImage:
        plan: WithPurchasePlan
        offer: rh-ocp-worker
        publisher: RedHat
        sku: rh-ocp-worker-gen1
        version: 4.15.2024072409
      type: Standard_DC4s_v3
platform:
  azure:
    region: eastus
EOF
echo "**********Check osImage from gen1 image, while vm type only supports Gen2**********"
error_key_words='controlPlane.platform.azure.osImage: Invalid value: \"rh-ocp-worker-gen1\": instance type supports HyperVGenerations [V2] but the specified image is for HyperVGeneration V1'
check_invalid_fields "${patch_file}" "${error_key_words}" || check_result=1

#Verify osImage from Gen2 image, while vm type only supports Gen1
cat > ${patch_file} << EOF
controlPlane:
  platform:
    azure:
      osImage:
        plan: WithPurchasePlan
        offer: rh-ocp-worker
        publisher: RedHat
        sku: rh-ocp-worker
        version: 4.15.2024072409
      type: Standard_NP10s
platform:
  azure:
    region: southcentralus
EOF
echo "**********Check osImage from Gen2 image, while vm type only supports Gen1**********"
error_key_words='controlPlane.platform.azure.osImage: Invalid value: \"rh-ocp-worker\": instance type supports HyperVGenerations [V1] but the specified image is for HyperVGeneration V2'
check_invalid_fields "${patch_file}" "${error_key_words}" || check_result=1

exit ${check_result}
