#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export http_proxy="http://204.90.115.172:8080"
export https_proxy="http://204.90.115.172:8080"

ibmz_eco_cloud_auth=/var/run/secrets/clouds.yaml
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)
installer_dir=/deploy
cluster_dir=/deploy/ocp_clusters/${cluster_name}

echo "$(date -u --rfc-3339=seconds) - Copying config from shared dir..."

pushd ${installer_dir}

cp -t "${installer_dir}" \
    "${SHARED_DIR}/terraform.tfvars" \
    ${ibmz_eco_cloud_auth}

cp -t "${cluster_dir}" \
    "${SHARED_DIR}/pull-secret"

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

echo "$(date -u --rfc-3339=seconds) - Deploying cluster on IBM Z Ecosystem Cloud..."
/entrypoint.sh apply &
wait "$!"

set +e
wait "$!"
ret="$?"
set -e

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"

touch /tmp/install-complete

sed 's/password: .*/password: REDACTED/' "${cluster_dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"

cp -t "${SHARED_DIR}" \
    "${cluster_dir}/ocp_install/auth/kubeconfig" \
    "${cluster_dir}/ocp_install/metadata.json"

exit "$ret"
