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
    local patch_file=$1 expected_error=$2 type=${3:-patch} ret=0

    echo -e "DEBUG: instal-config ${type} \n-----"
    cat "${patch_file}"

    install_dir=$(mktemp -d)
    if [[ "${type}" == "file" ]]; then
        cat "${patch_file}" > ${install_dir}/install-config.yaml
    else
        cat "${INSTALL_CONFIG}" > ${install_dir}/install-config.yaml
        yq-go m -x -i "${install_dir}/install-config.yaml" "${patch_file}"
    fi
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
# verify to specify publish: Mixed in install-config on azure platform
cat > ${patch_file} << EOF
publish: Mixed
EOF
echo "**********Check that installer fails when only specifying publish: Mixed**********"
error_key_words='publish: Invalid value: \"Mixed\": please specify the operator publishing strategy for mixed publish strategy'
check_invalid_fields "${patch_file}" "${error_key_words}" || check_result=1

# verify to specify publish:External and operatorPublishingStrategy in install-config
cat > ${patch_file} << EOF
publish: External
operatorPublishingStrategy:
  apiserver: External
  ingress: Internal
EOF
echo "**********Check that installer fails when specifying publish: External and operatorPublishingStrategy**********"
error_key_words='operatorPublishingStrategy: Invalid value: \"External\": operator publishing strategy is only allowed with mixed publishing strategy installs'
check_invalid_fields "${patch_file}" "${error_key_words}" || check_result=1

# verify to specify operatorPublishingStrategy only in install-config
cat > ${patch_file} << EOF
publish: ''
operatorPublishingStrategy:
  apiserver: External
  ingress: Internal
EOF
echo "**********Check that installer fails when specifying operatorPublishingStrategy only**********"
error_key_words='operatorPublishingStrategy: Invalid value: \"External\": operator publishing strategy is only allowed with mixed publishing strategy installs'
check_invalid_fields "${patch_file}" "${error_key_words}" || check_result=1

# verify to specify apiserver and ingress both are internal in install-config
cat > ${patch_file} << EOF
publish: Mixed
operatorPublishingStrategy:
  apiserver: Internal
  ingress: Internal
EOF
echo "**********Check that installer fails when specifying apiserver and ingress both are internal**********"
error_key_words='publish: Invalid value: \"Internal\": cannot set both fields to internal in a mixed cluster, use publish internal instead'
check_invalid_fields "${patch_file}" "${error_key_words}" || check_result=1

# verify to specify mixed publish on other platform
cat > ${patch_file} << EOF
apiVersion: v1
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
metadata:
  name: qe-test
platform:
  aws:
    region: us-east-2
pullSecret: '{"auths":{"dummy.com":{"auth":"dummy"}}}'
publish: Mixed
operatorPublishingStrategy:
  apiserver: External
  ingress: Internal
baseDomain: qe.devcluster.openshift.com
EOF
echo "**********Check that installer fails when specifying mixed publish on other platform**********"
error_key_words='publish: Invalid value: \"Mixed\": mixed publish strategy is not supported on \"aws\" platform'
check_invalid_fields "${patch_file}" "${error_key_words}" "file"|| check_result=1

exit ${check_result}
