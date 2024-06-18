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

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")


INSTALL_DIR="/tmp/installer"

mkdir -p "${INSTALL_DIR}"

echo -e "\nCopy ignition file to install dir"

cp "${SHARED_DIR}/${UNCONFIGURED_AGENT_IGNITION_FILENAME}" "${INSTALL_DIR}/" 

### Copy the CoreOS image from the auxiliary host
echo -e "\nCopying the CoreOS ISO image from the bastion host..."
scp -r "${SSHOPTS[@]}" "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}/${COREOS_IMAGE_NAME}" "${INSTALL_DIR}/"

### Create unconfigured ISO image
echo -e "\nCreating unconfigured image..."
coreos-installer iso ignition embed -f -i "${INSTALL_DIR}/${UNCONFIGURED_AGENT_IGNITION_FILENAME}" \
  -o "${INSTALL_DIR}/${UNCONFIGURED_AGENT_IMAGE_FILENAME}" "${INSTALL_DIR}/${COREOS_IMAGE_NAME}"

### Copy the unconfigured image to the auxiliary host, it will be used in other steps
echo -e "\nCopying the unconfigured ISO image into the bastion host..."
scp "${SSHOPTS[@]}" "${INSTALL_DIR}/${UNCONFIGURED_AGENT_IMAGE_FILENAME}" \
  "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}/${UNCONFIGURED_AGENT_IMAGE_FILENAME}"
