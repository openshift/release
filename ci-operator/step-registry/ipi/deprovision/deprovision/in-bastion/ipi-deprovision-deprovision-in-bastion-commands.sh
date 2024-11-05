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
    echo "Running Command: ${cmd}"
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
    echo "Copying the Installer logs and metadata to the artifacts directory..."
    cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"
    cp /tmp/installer/metadata.json "${ARTIFACT_DIR}"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'save_logs' EXIT TERM

BASTION_IP=$(<"${SHARED_DIR}/bastion_public_address")
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
REMOTE_DIR="/home/${BASTION_SSH_USER}"
REMOTE_INSTALL_DIR="${REMOTE_DIR}/installer/"
REMOTE_ENV_FILE="${REMOTE_DIR}/remote_env_file"

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit 0
fi

echo ${SHARED_DIR}/metadata.json

echo "Running the Installer's 'destroy cluster' command in bastion ..."
run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "source ${REMOTE_ENV_FILE}; export OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT='true'; ${REMOTE_DIR}/openshift-install --dir ${REMOTE_INSTALL_DIR} destroy cluster --log-level debug" &

set +e
wait "$!"
ret="$?"

# copy logs and quota.json if exist from bastion host
run_scp_from_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${REMOTE_INSTALL_DIR}" "/tmp"

if [[ -s "/tmp/$(basename ${REMOTE_INSTALL_DIR})/quota.json" ]]; then
    cp "/tmp/$(basename ${REMOTE_INSTALL_DIR})/quota.json" "${ARTIFACT_DIR}"
fi

exit "$ret"
