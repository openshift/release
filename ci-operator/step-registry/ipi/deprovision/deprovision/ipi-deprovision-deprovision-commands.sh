#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function save_logs() {
    echo "Copying the Installer logs to the artifacts directory..."
    cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'save_logs' EXIT TERM

export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini
export AWS_SHARED_CREDENTIALS_FILE=$CLUSTER_PROFILE_DIR/.awscred
export AZURE_AUTH_LOCATION=$CLUSTER_PROFILE_DIR/osServicePrincipal.json
export GOOGLE_CLOUD_KEYFILE_JSON=$CLUSTER_PROFILE_DIR/gce.json
export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
export OVIRT_CONFIG=${SHARED_DIR}/ovirt-config.yaml

if [[ "${CLUSTER_TYPE}" == "ibmcloud" ]]; then
  IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
  export IC_API_KEY
fi

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

echo ${SHARED_DIR}/metadata.json

if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
  export AZURE_AUTH_LOCATION=$SHARED_DIR/osServicePrincipal.json
fi

echo "Copying the installation artifacts to the Installer's asset directory..."
cp -ar "${SHARED_DIR}" /tmp/installer

# TODO: remove once BZ#1926093 is done and backported
if [[ "${CLUSTER_TYPE}" == "ovirt" ]]; then
  echo "Destroy bootstrap ..."
  set +e
  openshift-install --dir /tmp/installer destroy bootstrap
  set -e
fi

# Check if proxy is set
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  echo "Private cluster setting proxy"
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

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
