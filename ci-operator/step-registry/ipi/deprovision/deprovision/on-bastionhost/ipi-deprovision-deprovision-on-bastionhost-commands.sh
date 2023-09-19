#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function save_logs() {
    echo "Copying the Installer logs and metadata to the artifacts directory..."
    cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"
    cp /tmp/installer/metadata.json "${ARTIFACT_DIR}"
}

function destroy_on_bastionhost() {
  local ret

  bastion_ssh_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")
  bastion_public_address=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
  if [[ -n "${bastion_ssh_user}" ]] && [[ -n "${bastion_public_address}" ]]; then

    # Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
    # to be able to SSH.
    if ! whoami &> /dev/null; then
      if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
      else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
      fi
    fi

    echo "destroying cluster on the bastion host (${bastion_ssh_user}@${bastion_public_address})..."
    ssh -o StrictHostKeyChecking=no -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey" "${bastion_ssh_user}@${bastion_public_address}" "./openshift-install version; ./openshift-install destroy cluster --dir installer"
    ret=$?

    echo "Copy back installer artifacts from the bastion host..."
    scp -o StrictHostKeyChecking=no -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey" -r ${bastion_ssh_user}@${bastion_public_address}:/home/${bastion_ssh_user}/installer/* /tmp/installer/
  else
    echo "ERROR: Can not get bastion user/host, abort."
    return 1
  fi

  return $ret
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'save_logs' EXIT TERM

export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini
if [[ -f "${SHARED_DIR}/aws_minimal_permission" ]]; then
  echo "Setting AWS credential with minimal permision for installer"
  export AWS_SHARED_CREDENTIALS_FILE=${SHARED_DIR}/aws_minimal_permission
else
  export AWS_SHARED_CREDENTIALS_FILE=$CLUSTER_PROFILE_DIR/.awscred
fi

export AZURE_AUTH_LOCATION=$CLUSTER_PROFILE_DIR/osServicePrincipal.json
export GOOGLE_CLOUD_KEYFILE_JSON=$CLUSTER_PROFILE_DIR/gce.json
if [ -f "${SHARED_DIR}/gcp_min_permissions.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - Using the IAM service account for the minimum permissions testing on GCP..."
  export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/gcp_min_permissions.json"
fi
export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
export OVIRT_CONFIG=${SHARED_DIR}/ovirt-config.yaml

if [[ "${CLUSTER_TYPE}" == "ibmcloud"* ]]; then
  IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
  export IC_API_KEY
fi
if [[ "${CLUSTER_TYPE}" == "vsphere"* ]]; then
    # all vcenter certificates are in the file below
    export SSL_CERT_FILE=/var/run/vsphere8-secrets/vcenter-certificate
fi

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

if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
  export AZURE_AUTH_LOCATION=$SHARED_DIR/osServicePrincipal.json
  if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
    export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/ca.pem"
  fi
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

echo "Running the Installer's 'destroy cluster' command on bastionhost..."
destroy_on_bastionhost
ret="$?"
echo "Installer exit with code $ret"

if [[ -s /tmp/installer/quota.json ]]; then
        cp /tmp/installer/quota.json "${ARTIFACT_DIR}"
fi

exit "$ret"
