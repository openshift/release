#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

function run_command() {
    local cmd="$1"
    echo "$(date -u --rfc-3339=seconds) - Running Command: ${cmd}"
    eval "${cmd}"
}

function run_ssh_cmd() {
    local sshkey=$1
    local user=$2
    local host=$3
    local remote_cmd=$4

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    cmd="ssh ${options} -i \"${sshkey}\" ${user}@${host} \"${remote_cmd}\""
    run_command "$cmd" || return 2
    return 0
}

function run_scp_to_remote() {
    local sshkey=$1
    local user=$2
    local host=$3
    local src=$4
    local dest=$5

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    cmd="scp -r ${options} -i \"${sshkey}\" ${src} ${user}@${host}:${dest}"
    run_command "$cmd" || return 2
    return 0
}

function run_scp_from_remote() {
    local sshkey=$1
    local user=$2
    local host=$3
    local src=$4
    local dest=$5

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    cmd="scp -r ${options} -i \"${sshkey}\" ${user}@${host}:${src} ${dest}"
    run_command "$cmd" || return 2
    return 0
}

function save_logs() {
    echo "$(date -u --rfc-3339=seconds) - Copying the Installer logs and metadata to the artifacts directory..."
    cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"
    cp /tmp/installer/metadata.json "${ARTIFACT_DIR}"
    
  # Delete the ${REMOTE_SECRETS_DIR} as it may contain credential files
  run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "rm -rf ${REMOTE_SECRETS_DIR}"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'save_logs' EXIT TERM

BASTION_IP=$(<"${SHARED_DIR}/bastion_public_address")
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
REMOTE_DIR="/home/${BASTION_SSH_USER}"
REMOTE_INSTALL_DIR="${REMOTE_DIR}/installer/"
REMOTE_SECRETS_DIR="${REMOTE_DIR}/secrets/"
REMOTE_ENV_FILE="/tmp/remote_env_file"
touch "${REMOTE_ENV_FILE}"

run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "mkdir ${REMOTE_SECRETS_DIR}"

# Prepare credentials
# Update here to support intallation in bastion on different platforms
case "${CLUSTER_TYPE}" in
azure4|azuremag|azure-arm64)
    if [[ -f "${SHARED_DIR}/azure_managed_identity_osServicePrincipal.json" ]]; then
        echo "Setting AZURE credential using managed identity for installer"
        AZURE_AUTH_LOCATION="${SHARED_DIR}/azure_managed_identity_osServicePrincipal.json"
    else
        AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
    fi
    run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${AZURE_AUTH_LOCATION}" "${REMOTE_SECRETS_DIR}/osServicePrincipal.json"
    echo "export AZURE_AUTH_LOCATION='${REMOTE_SECRETS_DIR}/osServicePrincipal.json'" >> "${REMOTE_ENV_FILE}"
    ;;
gcp)
    if [[ -z "${ATTACH_BASTION_SA}" ]]; then
        GOOGLE_CLOUD_KEYFILE_JSON=${CLUSTER_PROFILE_DIR}/gce.json
	run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${GOOGLE_CLOUD_KEYFILE_JSON}" "${REMOTE_SECRETS_DIR}/gce.json"
	echo "export GOOGLE_CLOUD_KEYFILE_JSON='${REMOTE_SECRETS_DIR}/gce.json'" >> "${REMOTE_ENV_FILE}"
    else
	echo "The install on bastion will use the service-account attached to the bastion host, nothing to do"
    fi
    ;;
*) >&2 echo "No need to upload any credential files into bastion host for cluster type '${CLUSTER_TYPE}'"
esac

echo "$(date -u --rfc-3339=seconds) - Uploading '${REMOTE_ENV_FILE}' to bastion"
run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${REMOTE_ENV_FILE}" "${REMOTE_DIR}"

echo "$(date -u --rfc-3339=seconds) - Running the Installer's 'destroy cluster' command in bastion ..."
run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "source ${REMOTE_DIR}/$(basename $REMOTE_ENV_FILE); export OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT='true'; ${REMOTE_DIR}/openshift-install --dir ${REMOTE_INSTALL_DIR} destroy cluster --log-level debug" &

set +e
wait "$!"
ret="$?"

echo "$(date -u --rfc-3339=seconds) - Copy logs and quota.json if exist from bastion host"
run_scp_from_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${REMOTE_INSTALL_DIR}" "/tmp"

if [[ -s "/tmp/$(basename ${REMOTE_INSTALL_DIR})/quota.json" ]]; then
    cp "/tmp/$(basename ${REMOTE_INSTALL_DIR})/quota.json" "${ARTIFACT_DIR}"
fi

exit "$ret"
