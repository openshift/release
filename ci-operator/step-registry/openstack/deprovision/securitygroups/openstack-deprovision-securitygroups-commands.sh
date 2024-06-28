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

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

if [[ -d "${SHARED_DIR}/securitygroups" ]]; then
	for sg_id in "${SHARED_DIR}"/securitygroups/*; do
		echo "Deleting security group '$(basename $sg_id)'..."
		openstack security group delete "$(<"$sg_id")"
	done
fi