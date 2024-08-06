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

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=300 -o ServerAliveCountMax=10 "
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

function populate_artifact_dir() {
  set +e
  echo "Copying log bundle..."
  cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-$(date +%s).log"
  sed -i '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/terraform.txt"
  tar -czvf "${ARTIFACT_DIR}/terraform.tar.gz" --remove-files "${dir}/terraform.txt"
}

function write_install_status() {
  #Save exit code for must-gather to generate junit
  [[ -n "$ret" ]] && echo "$ret" >> "${SHARED_DIR}/install-status.txt"
}

function prepare_next_steps() {
  write_install_status
  set +e
  echo "Setup phase finished, prepare env for next steps"
  populate_artifact_dir

  echo "Copying required artifacts to shared dir"
  #Copy the auth artifacts to shared dir for the next steps
  cp \
      -t "${SHARED_DIR}" \
      "${dir}/auth/kubeconfig" \
      "${dir}/auth/kubeadmin-password" \
      "${dir}/metadata.json"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'prepare_next_steps' EXIT TERM INT

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

if [[ -f "${SHARED_DIR}/bastion_public_address" ]]; then
    BASTION_IP=$(<"${SHARED_DIR}/bastion_public_address")
    BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")
else
    echo "This step is used to install cluster in bastion host, but could not find bastion_public_address in SHARED_DIR, exit..."
    exit 1
fi

REMOTE_DIR="/home/${BASTION_SSH_USER}"
REMOTE_INSTALL_DIR="${REMOTE_DIR}/installer/"
REMOTE_ENV_FILE="/tmp/remote_env_file"
dir=/tmp/installer
mkdir "${dir}/"

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

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
    run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${AZURE_AUTH_LOCATION}" "${REMOTE_DIR}/osServicePrincipal.json"
    echo "export AZURE_AUTH_LOCATION='${REMOTE_DIR}/osServicePrincipal.json'" >> "${REMOTE_ENV_FILE}"
    ;;
*) >&2 echo "No need to upload any credential files into bastion host for cluster type '${CLUSTER_TYPE}'"
esac

echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/install-config.yaml

run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "mkdir ${REMOTE_INSTALL_DIR}"
run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${SHARED_DIR}/install-config.yaml" "${REMOTE_INSTALL_DIR}"
# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${SSH_PRIV_KEY_PATH}" "/home/${BASTION_SSH_USER}/.ssh/"

# upload installer binary
installer_bin=$(which openshift-install)
echo "openshift-install binary path: $installer_bin"
run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${installer_bin}" "${REMOTE_DIR}"

# save ENV to REMOTE_ENV_FILE for installation on bastion
echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" >> "${REMOTE_ENV_FILE}"
[[ -n "${OPENSHIFT_INSTALL_PRESERVE_BOOTSTRAP}" ]] && echo "export OPENSHIFT_INSTALL_PRESERVE_BOOTSTRAP=${OPENSHIFT_INSTALL_PRESERVE_BOOTSTRAP}" >> "${REMOTE_ENV_FILE}"
if [ "${FIPS_ENABLED:-false}" = "true" ]; then echo "export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true" >> "${REMOTE_ENV_FILE}"; fi
echo "export TF_LOG=${TF_LOG}" >> "${REMOTE_ENV_FILE}"
echo "export TF_LOG_CORE=${TF_LOG_CORE}" >> "${REMOTE_ENV_FILE}"
echo "export TF_LOG_PROVIDER=${TF_LOG_PROVIDER}" >> "${REMOTE_ENV_FILE}"
run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${REMOTE_ENV_FILE}" "${REMOTE_DIR}"

# Create manifests
echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"
run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "source ${REMOTE_DIR}/$(basename $REMOTE_ENV_FILE); ${REMOTE_DIR}/openshift-install --dir='${REMOTE_INSTALL_DIR}' create manifests" &
wait "$!"

echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${item}" "${REMOTE_INSTALL_DIR}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \)

run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "mkdir ${REMOTE_INSTALL_DIR}/tls"
while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${item}" "${REMOTE_INSTALL_DIR}/tls/${manifest##tls_}"
done <   <( find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print0)

# Install cluster
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
echo "export TF_LOG_PATH='${REMOTE_INSTALL_DIR}/terraform.txt'" >> ${REMOTE_ENV_FILE}
run_scp_to_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${REMOTE_ENV_FILE}" "${REMOTE_DIR}"

set +o errexit
run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "source ${REMOTE_DIR}/$(basename $REMOTE_ENV_FILE); ${REMOTE_DIR}/openshift-install --dir='${REMOTE_INSTALL_DIR}' create cluster --log-level debug 2>&1" | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
ret="$?"
echo "Installer exit with code $ret"
# copy install artifacts from bastion host to ${dir} for reference
echo "copy back installer artifacts from bastion host"
run_scp_from_remote "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_IP}" "${REMOTE_INSTALL_DIR}" "${dir%/*}"
set -o errexit

# debug
echo "the content of ${dir} in local container "
ls -ltra ${dir}

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

if test "${ret}" -eq 0 ; then
    touch  "${SHARED_DIR}/success"
    # Save console URL in `console.url` file so that ci-chat-bot could report success
    echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

exit ${ret}
