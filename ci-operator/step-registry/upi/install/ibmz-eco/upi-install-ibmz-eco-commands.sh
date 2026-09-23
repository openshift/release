#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export http_proxy="http://204.90.115.172:8080"
export https_proxy="http://204.90.115.172:8080"

ibmz_eco_cloud_auth=/var/run/secrets/openstack/clouds.yaml
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)
installer_dir=/deploy
cluster_dir=${installer_dir}/ocp_clusters/${cluster_name}

echo "$(date -u --rfc-3339=seconds) - Copying config from shared dir..."

mkdir -p ${cluster_dir}
pushd ${installer_dir}

cp -t "${installer_dir}" \
    "${SHARED_DIR}/terraform.tfvars" \
    ${ibmz_eco_cloud_auth}

cp -t "${cluster_dir}" \
    "${SHARED_DIR}/pull-secret"

ocp_version=$(cat ${installer_dir}/terraform.tfvars | grep openshift_version | cut -d= -f2 | sed -e 's/"//' -e 's/"$//')

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

echo "$(date -u --rfc-3339=seconds) - Deploying cluster on IBM Z Ecosystem Cloud... OpenShift ${ocp_version}"
/entrypoint.sh apply &

set +e
wait "$!"
ret="$?"
set -e

if [ $ret -ne 0 ]; then
  set +e
  # Attempt to gather tfstate file and logs.
  echo "$(date -u --rfc-3339=seconds) - Install failed, gathering cluster directory with tfstate file..."
  gzip "${cluster_dir}/terraform.tfstate"
  tar --exclude="./ocp_install/bootstrap.ign" -cv -f cluster_dir.tgz -C ${cluster_dir} .
  cp -t "${SHARED_DIR}" \
      cluster_dir.tgz
  set -e
  exit "$ret"
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"
touch /tmp/install-complete

sed 's/password: .*/password: REDACTED/' "${cluster_dir}/ocp_install/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"

gzip "${cluster_dir}/terraform.tfstate"
tar --exclude="./ocp_install/bootstrap.ign" -cv -f cluster_dir.tgz -C ${cluster_dir} .

oc --kubeconfig="${cluster_dir}/ocp_install/auth/kubeconfig" config set clusters.${cluster_name}.proxy-url ${http_proxy}

cp -t "${SHARED_DIR}" \
    "${cluster_dir}/ocp_install/auth/kubeconfig" \
    "${cluster_dir}/ocp_install/metadata.json" \
    cluster_dir.tgz

KUBECONFIG="${SHARED_DIR}/kubeconfig"
export KUBECONFIG

exit "$ret"
