#!/usr/bin/env bash

set -Eeuo pipefail

CLUSTER_NAME="$(        yq -r '.metadata.name'                           "${SHARED_DIR}/install-config.yaml")"
OS_SUBNET_RANGE="$(     yq -r '.networking.machineNetwork[0].cidr'       "${SHARED_DIR}/install-config.yaml")"
SVC_SUBNET_RANGE="$(    yq -r '.networking.serviceNetwork[0]'            "${SHARED_DIR}/install-config.yaml")"
CLUSTER_NETWORK_CIDR="$(yq -r '.networking.clusterNetwork[0].cidr'       "${SHARED_DIR}/install-config.yaml")"
HOST_PREFIX="$(         yq -r '.networking.clusterNetwork[0].hostPrefix' "${SHARED_DIR}/install-config.yaml")"
OS_NETWORKING_TYPE="$(  yq -r '.networking.networkType'                  "${SHARED_DIR}/install-config.yaml")"
OS_EXTERNAL_DNS="$(     yq -c '.platform.openstack.externalDNS'          "${SHARED_DIR}/install-config.yaml")"

if [[ ! -f '/var/lib/openshift-install/upi/inventory.yaml' ]]; then
	echo 'ERROR: Missing inventory file at /var/lib/openshift-install/upi/inventory.yaml. The step requires OCP v4.12 or above.'
	exit 1
fi

declare errexit=0

if [[ "$OS_SUBNET_RANGE" == 'null' ]]; then
	echo 'ERROR: Required install-config.yaml field empty: .networking.machineNetwork[0].cidr'
	errexit=1
fi

if [[ "$SVC_SUBNET_RANGE" == 'null' ]]; then
	echo 'ERROR: Required install-config.yaml field empty: .networking.serviceNetwork[0]'
	errexit=1
fi

if [[ "$CLUSTER_NETWORK_CIDR" == 'null' ]]; then
	echo 'ERROR: Required install-config.yaml field empty: .networking.clusterNetwork[0].cidr'
	errexit=1
fi

if [[ "$HOST_PREFIX" == 'null' ]]; then
	echo 'ERROR: Required install-config.yaml field empty: .networking.clusterNetwork[0].hostPrefix'
	errexit=1
fi

if [[ "$OS_NETWORKING_TYPE" == 'null' ]]; then
	echo 'ERROR: Required install-config.yaml field empty: .networking.networkType'
	errexit=1
fi

cp /var/lib/openshift-install/upi/inventory.yaml "${SHARED_DIR}/inventory.yaml"

if [[ "${CONFIG_TYPE}" == "dual-stack-upi" ]]; then
	# Enable IPv6 part of the config by uncommenting os_subnet6
	sed -i -re 's/^(\s*)#(os_subnet6:.*)/\1\2/' "${SHARED_DIR}/inventory.yaml"
	yq --yaml-output --in-place ".
		| .all.hosts.localhost.os_subnet6_range = \"${OS_SUBNET_V6_RANGE}\"
	" "${SHARED_DIR}/inventory.yaml"
fi

yq --yaml-output --in-place ".
	| .all.hosts.localhost.os_subnet_range = \"${OS_SUBNET_RANGE}\"
	| .all.hosts.localhost.os_flavor_master = \"$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR")\"
	| .all.hosts.localhost.os_flavor_worker = \"$(<"${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")\"
	| .all.hosts.localhost.os_image_rhcos = \"rhcos-${CLUSTER_NAME}\"
	| .all.hosts.localhost.svc_subnet_range = \"${SVC_SUBNET_RANGE}\"
	| .all.hosts.localhost.cluster_network_cidrs = \"${CLUSTER_NETWORK_CIDR}\"
	| .all.hosts.localhost.host_prefix = \"${HOST_PREFIX}\"
	| .all.hosts.localhost.os_networking_type = \"${OS_NETWORKING_TYPE}\"
	| .all.hosts.localhost.os_external_dns = $OS_EXTERNAL_DNS
	| .all.hosts.localhost.os_external_network = \"$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")\"
	| .all.hosts.localhost.os_api_fip = \"$(<"${SHARED_DIR}/API_IP")\"
	| .all.hosts.localhost.os_ingress_fip = \"$(<"${SHARED_DIR}/INGRESS_IP")\"
	| del(.all.hosts.localhost.os_bootstrap_fip)
" "${SHARED_DIR}/inventory.yaml"

cp "${SHARED_DIR}/inventory.yaml" "${ARTIFACT_DIR}/"

exit $errexit
