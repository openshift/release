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

PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
INSTALL_DIR="${INSTALL_DIR:-/tmp/ove}"
mkdir -p "${INSTALL_DIR}"

dnf install --nodocs -y skopeo xorriso podman

git clone https://github.com/openshift/agent-installer-utils.git $INSTALL_DIR

cd $INSTALL_DIR/tools/iso_builder/hack


./build-ove-image.sh --release-image-url "${OPENSHIFT_INSTALL_RELEASE_IMAGE}" \
  --pull-secret-file "$PULL_SECRET_PATH" \
  --ssh-key-file "${CLUSTER_PROFILE_DIR}/ssh-key" \
  --dir ./output

PAYLOAD_VERSION=${OPENSHIFT_INSTALL_RELEASE_IMAGE#*:}

scp "${SSHOPTS[@]}" output/$PAYLOAD_VERSION/ove/output/agent-ove.x86_64.iso "root@${AUX_HOST}:/opt/html/agent-ove-$PAYLOAD_VERSION.x86_64.iso"
