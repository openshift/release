#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function save_logs() {
    echo "Copying the Installer logs and metadata to the artifacts directory..."
    cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"
    cp /tmp/installer/metadata.json "${ARTIFACT_DIR}"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'save_logs' EXIT TERM

export AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials"

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

echo ${SHARED_DIR}/metadata.json

if [[ -f "${SHARED_DIR}/azure_minimal_permission" ]]; then
    echo "Setting AZURE credential with minimal permissions for installer"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/azure_minimal_permission
fi

if [[ "${CLUSTER_TYPE}" == "azurestack" && -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
  export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/ca.pem"
fi


echo "Copying the installation artifacts to the Installer's asset directory..."
cp -ar "${SHARED_DIR}" /tmp/installer

echo "Running the Installer's 'destroy cluster' command..."
OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT="true"; export OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT
openshift-install --dir /tmp/installer destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

if [[ -s /tmp/installer/quota.json ]]; then
        cp /tmp/installer/quota.json "${ARTIFACT_DIR}"
fi

exit "$ret"
