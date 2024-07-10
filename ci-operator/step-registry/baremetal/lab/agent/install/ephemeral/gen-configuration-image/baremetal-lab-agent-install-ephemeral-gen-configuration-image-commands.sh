#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

function oinst() {
  /tmp/openshift-install --dir="${INSTALL_DIR}" --log-level=debug "${@}" 2>&1 | grep\
   --line-buffered -v 'password\|X-Auth-Token\|UserData:'
}

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
INSTALL_DIR="/tmp/installer"

mkdir -p "${INSTALL_DIR}"

echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
oc adm release extract -a "$PULL_SECRET_PATH" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
   --command=openshift-install --to=/tmp

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"
cp "${SHARED_DIR}/agent-config.yaml" "${INSTALL_DIR}/"


echo -e "\nCreating agent configuration image..."
oinst agent create config-image

echo -e "\nPreparing KUBECONFIG files for next steps in SHARED_DIR..."
cp "${INSTALL_DIR}/auth/kubeconfig" "${SHARED_DIR}/"
cp "${INSTALL_DIR}/auth/kubeadmin-password" "${SHARED_DIR}/"

### Copy the agent configuration image to the auxiliary host
echo -e "\nCopying the agent configuration image into the bastion host..."
scp "${SSHOPTS[@]}" "${INSTALL_DIR}/${AGENT_CONFIGURATION_IMAGE_NAME}" "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}/${AGENT_CONFIGURATION_IMAGE_NAME}"

echo -e "\nCopying the agent configuration image to artifact dir..."

cp "${INSTALL_DIR}/${AGENT_CONFIGURATION_IMAGE_NAME}" "${ARTIFACT_DIR}/"

echo -e "### Adjusting file permissions..."
timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash - <<EOF
chmod 644 /opt/html/${CLUSTER_NAME}/*.iso
EOF
