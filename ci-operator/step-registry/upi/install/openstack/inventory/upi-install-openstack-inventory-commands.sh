#!/usr/bin/env bash

set -Eeuo pipefail

CLUSTER_NAME="$(        yq -r '.metadata.name'                           "${SHARED_DIR}/install-config.yaml")"
OS_SUBNET_RANGE="$(     yq -r '.networking.machineNetwork[0].cidr'       "${SHARED_DIR}/install-config.yaml")"
SVC_SUBNET_RANGE="$(    yq -r '.networking.serviceNetwork[0]'            "${SHARED_DIR}/install-config.yaml")"
CLUSTER_NETWORK_CIDR="$(yq -r '.networking.clusterNetwork[0].cidr'       "${SHARED_DIR}/install-config.yaml")"
HOST_PREFIX="$(         yq -r '.networking.clusterNetwork[0].hostPrefix' "${SHARED_DIR}/install-config.yaml")"
OS_NETWORKING_TYPE="$(  yq -r '.networking.networkType'                  "${SHARED_DIR}/install-config.yaml")"
OS_EXTERNAL_DNS="$(     yq -c '.platform.openstack.externalDNS'          "${SHARED_DIR}/install-config.yaml")"


if [[ "$OS_SUBNET_RANGE" == 'null' ]]; then
	OS_SUBNET_RANGE="172.16.0.0/24"
fi

if [[ "$SVC_SUBNET_RANGE" == 'null' ]]; then
	SVC_SUBNET_RANGE="172.30.0.0/16"
fi

if [[ "$CLUSTER_NETWORK_CIDR" == 'null' ]]; then
	CLUSTER_NETWORK_CIDR="10.128.0.0/14"
fi

if [[ "$HOST_PREFIX" == 'null' ]]; then
	HOST_PREFIX="23"
fi

if [[ "$OS_NETWORKING_TYPE" == 'null' ]]; then
	OS_NETWORKING_TYPE="OpenshiftSDN"
fi

yq --yaml-output "$(cat <<-EOF
	.
	| .all.hosts.localhost.os_subnet_range="${OS_SUBNET_RANGE}"
	| .all.hosts.localhost.os_flavor_master="$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR")"
	| .all.hosts.localhost.os_flavor_worker="$(<"${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")"
	| .all.hosts.localhost.os_image_rhcos="rhcos-${CLUSTER_NAME}"
	| .all.hosts.localhost.svc_subnet_range="${SVC_SUBNET_RANGE}"
	| .all.hosts.localhost.cluster_network_cidrs="${CLUSTER_NETWORK_CIDR}"
	| .all.hosts.localhost.host_prefix="${HOST_PREFIX}"
	| .all.hosts.localhost.os_networking_type="${OS_NETWORKING_TYPE}"
	| .all.hosts.localhost.os_external_dns=$OS_EXTERNAL_DNS
	| .all.hosts.localhost.os_external_network="$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")"
	| .all.hosts.localhost.os_api_fip="$(<"${SHARED_DIR}/API_IP")"
	| .all.hosts.localhost.os_ingress_fip="$(<"${SHARED_DIR}/INGRESS_IP")"
	| del(.all.hosts.localhost.os_bootstrap_fip)
	EOF
	)" '/var/lib/openshift-install/upi/inventory.yaml' > "${SHARED_DIR}/inventory.yaml"

cp "${SHARED_DIR}/inventory.yaml" "${ARTIFACT_DIR}/"
