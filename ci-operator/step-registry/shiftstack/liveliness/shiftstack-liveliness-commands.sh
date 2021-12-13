#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
# Recycling BASTION_FLAVOR as it's a small flavor we can re-use.
TESTING_FLAVOR="${TESTING_FLAVOR:-$(<"${SHARED_DIR}/BASTION_FLAVOR")}"

# TODO - this logic could leave in shiftstack-ci/server script at some point.
ssh-keygen -t rsa -N "" -f shiftstack-ci
chmod 0600 shiftstack-ci
eval "$(ssh-agent)"
if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${IMAGE_USER:-centos}:x:$(id -u):0:${IMAGE_USER:-centos} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi
ssh-add shiftstack-ci
openstack keypair create --public-key shiftstack-ci.pub shiftstack-ci-${CLUSTER_NAME} >/dev/null

set +e
echo "DEBUG: Running liveliness check script..."
./server.sh -d -t -u ${IMAGE_USER} -f ${TESTING_FLAVOR} -i ${TESTING_IMAGE} -e ${OPENSTACK_EXTERNAL_NETWORK} -k shiftstack-ci-${CLUSTER_NAME} shiftstack-ci-${CLUSTER_NAME}
RC=$?
echo "DEBUG: Removing shiftstack-ci-${CLUSTER_NAME} keypair"
openstack keypair delete shiftstack-ci-${CLUSTER_NAME}
rm shiftstack-ci shiftstack-ci.pub
set -e

if [ $RC -ne 0 ]; then
  echo "ERROR: Some errors were found during liveliness check..."
  exit 1
fi

echo "DEBUG: Cloud is alive!"
