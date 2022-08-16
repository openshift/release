#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

POWERVS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.powervscred"
export POWERVS_SHARED_CREDENTIALS_FILE

if [[ "${CLUSTER_TYPE}" == "powervs" ]]; then
  IBMCLOUD_API_KEY=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_API_KEY")
  export IBMCLOUD_API_KEY
fi

export POWERVS_AUTH_FILEPATH=${SHARED_DIR}/powervs-config.json

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

echo ${SHARED_DIR}/metadata.json

echo "Copying the installation artifacts to the Installer's asset directory..."
cp -ar "${SHARED_DIR}" /tmp/installer

echo "Running the Installer's 'destroy cluster' command..."
OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT="true"; export OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT
# TODO: Remove after infra bugs are fixed 
# TO confirm resources are cleared properly
set +e
for i in {1..3}; do 
  echo "Destroying cluster $i attempt..."
  echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
  openshift-install --dir /tmp/installer destroy cluster 
  ret="$?"
  echo "ret=${ret}"
  if [ ${ret} -eq 0 ]; then
    break
  fi
done
set -e

echo "Copying the Installer logs to the artifacts directory..."
cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"
if [[ -s /tmp/installer/quota.json ]]; then
	cp /tmp/installer/quota.json "${ARTIFACT_DIR}"
fi

exit "$ret"
