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
trap 'save_artifacts; if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

function save_artifacts()
{
  set +o errexit
  current_time=$(date +%s)
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${install_dir}/.openshift_install.log" > "${ARTIFACT_DIR}/cluster_2_openshift_install-${current_time}.log"

  set -o errexit
}

check_result=0

base_domain=$(yq-go r ${SHARED_DIR}/install-config.yaml 'baseDomain')
cluster_name=$(yq-go r ${SHARED_DIR}/install-config.yaml 'metadata.name')
install_dir="/tmp/${cluster_name}"
mkdir -p ${install_dir}
cat "${SHARED_DIR}/install-config.yaml" > "${install_dir}/install-config.yaml"

export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
openshift-install create cluster --dir ${install_dir} || true

error_key_words="api.${base_domain} CNAME record already exists in ${cluster_name} and might be in use by another cluster"
echo "********Check that expected error in openshift-install.log when creating 2nd cluster********"
if grep -q "${error_key_words}" ${install_dir}/.openshift_install.log; then
    echo "INFO: installer exit with expected error!"
else
    echo "ERROR: could not find expected error in openshift_install.log"
    check_result=1
fi

exit ${check_result}
