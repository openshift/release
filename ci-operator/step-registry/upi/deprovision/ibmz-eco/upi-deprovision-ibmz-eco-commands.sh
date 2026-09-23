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
    "${SHARED_DIR}/cluster_dir.tgz"

cd ${cluster_dir} && tar -xv -f cluster_dir.tgz
gzip -d "${cluster_dir}/terraform.tfstate.gz"
touch "${cluster_dir}/ocp_install/bootstrap.ign"
cd ${installer_dir}

ocp_version=$(cat ${installer_dir}/terraform.tfvars | grep openshift_version | cut -d= -f2 | sed -e 's/"//' -e 's/"$//')

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_DEPROVISION_START"

echo "$(date -u --rfc-3339=seconds) - Destroying cluster on IBM Z Ecosystem Cloud... OpenShift ${ocp_version}"
/entrypoint.sh destroy &

set +e
wait "$!"
ret="$?"
set -e

if [ $ret -ne 0 ]; then
  set +e
  # Attempt to gather tfstate file and logs.
  echo "$(date -u --rfc-3339=seconds) - Destroy failed, gathering tfstate file and logs..."
  gzip "${cluster_dir}/terraform.tfstate"
  cp -t "${SHARED_DIR}" \
      "${cluster_dir}/terraform.tfstate.gz"
  set -e
  exit "$ret"
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_DEPROVISION_END"

touch /tmp/deprovision-complete

exit "$ret"
