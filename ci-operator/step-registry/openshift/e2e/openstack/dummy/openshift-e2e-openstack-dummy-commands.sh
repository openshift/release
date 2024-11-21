#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function info() {
  printf '%s: INFO: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
# if test -f "${SHARED_DIR}/proxy-conf.sh"
# then
#	# shellcheck disable=SC1090
#	source "${SHARED_DIR}/proxy-conf.sh"
# fi

if [[ ! -f "${SHARED_DIR}/underlying-kubeconfig" ]]; then
	info "underlying-kubeconfig wasn't found"
    exit 1
fi

# Get openstack catalog list from the underlying ocp (where run the RHOSO Control Plane)
export KUBECONFIG=${SHARED_DIR}/underlying-kubeconfig 
oc rsh -n openstack openstackclient openstack catalog list