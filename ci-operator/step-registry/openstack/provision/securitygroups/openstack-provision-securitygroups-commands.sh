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

CLUSTER_NAME="$(<"${SHARED_DIR}/CLUSTER_NAME")"

if [[ -n "$ADDITIONAL_SECURITY_GROUP_RULES" ]]; then
	sg_name='additional_workers'
	sg_id="$(openstack security group create "$sg_name" --description "${CLUSTER_NAME}: additional security group for the compute nodes" -f value -c id)"
	printf '%s' "$sg_id" > "${SHARED_DIR}/securitygroups"
	(
		IFS=','
		for service in $ADDITIONAL_SECURITY_GROUP_RULES; do
			case $service in
				netperf)
					echo "Adding ${service} rule to security group ${sg_id}" 
					openstack security group rule create "$sg_id" --protocol tcp --dst-port 12865:12865 --remote-ip 0.0.0.0/0
					;;
				*)
					echo "No known security group rule matches service '$service'. Exiting."
					exit 1
					;;
			esac
		done
	)
fi