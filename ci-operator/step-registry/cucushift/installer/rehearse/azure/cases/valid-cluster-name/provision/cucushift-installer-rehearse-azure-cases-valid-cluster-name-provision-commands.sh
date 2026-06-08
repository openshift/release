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
# verify the invalid cluster name that ends with special characters, e.g "-"
# ERROR: failed to fetch Master Machines: failed to load asset \"Install Config\": failed to create install config: invalid \"install-config.yaml\" file: metadata.name: Invalid value: \"qe-test-\": a lowercase RFC 1123 subdomain must consist of lower case alphanumeric characters, '-' or '.', and must start and end with an alphanumeric character (e.g. 'example.com', regex used for validation is '[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*')
cat > ${patch_file} << EOF
metadata:
  name: qe-test-
EOF
echo "**********Check the invalid cluster name end with special characters fails with the proper error message**********"
error_key_words='metadata.name: Invalid value: \"qe-test-\"'
check_invalid_fields "${patch_file}" "${error_key_words}" || check_result=1

# verify the invalid cluster name that contains upper case chars
cat > ${patch_file} << EOF
metadata:
  name: Qe-test
EOF
echo "**********Check the invalid cluster name that contains upper case chars**********"
error_key_words='metadata.name: Invalid value: \"Qe-test\": cluster name must begin with a lower-case letter'
check_invalid_fields "${patch_file}" "${error_key_words}" || check_result=1

# verify the invalid cluster name that starts with number
cat > ${patch_file} << EOF
metadata:
  name: 123.qe-test
EOF
echo "**********Check the invalid cluster name that starts with number**********"
error_key_words='metadata.name: Invalid value: \"123.qe-test\": cluster name must begin with a lower-case letter'
check_invalid_fields "${patch_file}" "${error_key_words}" || check_result=1

exit ${check_result}
