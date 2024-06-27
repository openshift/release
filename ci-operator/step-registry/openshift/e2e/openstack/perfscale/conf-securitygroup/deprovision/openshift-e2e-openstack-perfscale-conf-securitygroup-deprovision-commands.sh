#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

# Deleting the network-perf security group
NETWORK_PERF_SG=${NETWORK_PERF_SG:-"network-perf-sg"}

if ! openstack security group show "${NETWORK_PERF_SG}" >/dev/null; then
	echo "ERROR: The network-perf security group does not exist: ${NETWORK_PERF_SG}. Nothing to delete"
    exit 0
fi

echo "Deleting the Security Group $NETWORK_PERF_SG"
openstack security group delete $NETWORK_PERF_SG