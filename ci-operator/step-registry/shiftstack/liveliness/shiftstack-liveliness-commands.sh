#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
# Recycling BASTION_FLAVOR as it's a small flavor we can re-use.
TESTING_FLAVOR="${TESTING_FLAVOR:-$(<"${SHARED_DIR}/BASTION_FLAVOR")}"
ZONES="${ZONES:-$(<"${SHARED_DIR}/ZONES")}"

AZ_ARG=""
if [ -n "${ZONES}" ]; then
  IFS=' ' read -ra ZONES <<< "$ZONES"
  AZ_ARG="-z ${ZONES[0]}"
fi

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

set +e
echo "DEBUG: Running liveliness check script..."
./server.sh -d -t -l -f ${TESTING_FLAVOR} -i ${TESTING_IMAGE} -e ${OPENSTACK_EXTERNAL_NETWORK} ${AZ_ARG} shiftstack-ci-${CLUSTER_NAME}
RC=$?
set -e

if [ $RC -ne 0 ]; then
  echo "ERROR: Some errors were found during liveliness check..."
  exit 1
fi

echo "DEBUG: Cloud is alive!"
