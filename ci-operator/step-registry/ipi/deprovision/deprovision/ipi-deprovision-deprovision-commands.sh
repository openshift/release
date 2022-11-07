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

if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]]; then
  # C2S/SC2S regions do not support destory
  #   replace ${AWS_REGION} with source_region(us-east-1) in metadata.json as a workaround"
  
  # downloading jq
  curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq && chmod +x /tmp/jq

  source_region=$(/tmp/jq -r ".\"${LEASED_RESOURCE}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  sed -i "s/${LEASED_RESOURCE}/${source_region}/" "/tmp/installer/metadata.json"
fi

# TODO: remove once BZ#1926093 is done and backported
if [[ "${CLUSTER_TYPE}" == "ovirt" ]]; then
  echo "Destroy bootstrap ..."
  set +e
  openshift-install --dir /tmp/installer destroy bootstrap
  set -e
fi

# Check if proxy is set
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]]; then
    echo "proxy-conf.sh detected, but not reqquired by C2S/SC2S while destroying cluster, skip proxy setting"
  else
    echo "Private cluster setting proxy"
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
  fi
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
