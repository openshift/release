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

# Getting the machine network CIDR for minimal, dual-stack-upi, proxy and dualstack config types. 
case "$CONFIG_TYPE" in
	minimal|dual-stack-upi)
		machineNetwork_v4_cidr="10.0.0.0/16"
		if [[ "${CONFIG_TYPE}" == "dual-stack-upi" ]]; then
			machineNetwork_v6_cidr="${OS_SUBNET_V6_RANGE}"
		fi
		;;
	proxy*)
		machineNetwork_v4_cidr="$(<"${SHARED_DIR}"/MACHINES_SUBNET_RANGE)"
		;;
	dualstack*)
		machineNetwork_v4_cidr="${MACHINES_SUBNET_v4_RANGE}"
		machineNetwork_v6_cidr="${MACHINES_SUBNET_v6_RANGE}"
		;;
	*)
		echo "No valid install config type specified. Please check CONFIG_TYPE"
		exit 1
		;;
esac

if [[ -n "$ADDITIONAL_SECURITY_GROUP_RULES" ]]; then
	sg_name="${CLUSTER_NAME}-worker-additional"
	sg_id="$(openstack security group create "$sg_name" --description "${CLUSTER_NAME}: additional security group for the compute nodes" -f value -c id)"
	printf '%s' "$sg_id" > "${SHARED_DIR}/securitygroups"
	(
		IFS=','
		for service in $ADDITIONAL_SECURITY_GROUP_RULES; do
			case $service in
				netperf)
					echo "Adding ${service} rule to security group ${sg_id}" 
					openstack security group rule create "$sg_id" --protocol tcp --dst-port 12865:12865 --remote-ip 0.0.0.0/0 --description netperf
					openstack security group rule create "$sg_id" --protocol tcp --dst-port 22865:22865 --remote-ip 0.0.0.0/0 --description iperf3
					openstack security group rule create "$sg_id" --protocol tcp --dst-port 30000:30000 --remote-ip 0.0.0.0/0 --description uperf
					openstack security group rule create "$sg_id" --protocol tcp --dst-port 32000:47000 --remote-ip $machineNetwork_v4_cidr --description netserver-tcp
					openstack security group rule create "$sg_id" --protocol udp --dst-port 32000:62000 --remote-ip $machineNetwork_v4_cidr --description netserver-udp
					;;
				*)
					echo "No known security group rule matches service '$service'. Exiting."
					exit 1
					;;
			esac
		done
	)
fi