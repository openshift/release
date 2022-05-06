#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")

mkdir -p "${ARTIFACT_DIR}/nodes"

openstack server list | grep "$CLUSTER_NAME" > "${ARTIFACT_DIR}/openstack_nodes.log"

for server in $(openstack server list -c Name -f value | grep "$CLUSTER_NAME" | sort); do
	echo -e "\n$ openstack server show $server" >> "${ARTIFACT_DIR}/openstack_nodes.log"
	openstack server show $server               >> "${ARTIFACT_DIR}/openstack_nodes.log"

	openstack console log show $server          &> "${ARTIFACT_DIR}/nodes/console_${server}.log"
done

openstack port list | grep "$CLUSTER_NAME" > "${ARTIFACT_DIR}/openstack_ports.log"

for port in $(openstack port list -c Name -f value | grep "$CLUSTER_NAME" | sort); do
	echo -e "\n$ openstack port show $port" >> "${ARTIFACT_DIR}/openstack_ports.log"
	openstack port show $port               >> "${ARTIFACT_DIR}/openstack_ports.log"
done
