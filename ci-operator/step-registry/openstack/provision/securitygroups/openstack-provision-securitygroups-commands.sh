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

mkdir -p "${SHARED_DIR}/securitygroups"

case ${ADDITIONAL_SECURITY_GROUP_RULES} in

	netperf)
		sg_id="$(openstack security group create netperf --description "Security group for running network-perf test on the Worker Nodes" -f value -c id)"
		openstack security group rule create "$sg_id" --protocol tcp --dst-port 12865:12865 --remote-ip 0.0.0.0/0
		printf '%s' "$sg_id" > "${SHARED_DIR}/securitygroups/netperf"
    ;;

	*)
    	echo "None security group was set"
		exit 1
    ;;

esac