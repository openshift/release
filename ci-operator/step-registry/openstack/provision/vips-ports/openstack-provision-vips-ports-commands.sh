#!/usr/bin/env bash

# This script will create two neutron ports. One for the API VIP and another for the ingress VIP.
# The resources UUIDs are written in SHARED_DIR.

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE}" != *"singlestackv6"* && "$CONFIG_TYPE" != *"dualstack"* ]]; then
    echo "Skipping step due to CONFIG_TYPE not being singlestackv6 or dualstack."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
CONTROL_PLANE_NETWORK="${CONTROL_PLANE_NETWORK:-$(<"${SHARED_DIR}/CONTROL_PLANE_NETWORK")}"
CONTROL_PLANE_SUBNET_V6="${CONTROL_PLANE_SUBNET_V6:-$(<"${SHARED_DIR}/CONTROL_PLANE_SUBNET_V6")}"

NET_ARGS="--network $CONTROL_PLANE_NETWORK"
if [[ "${CONFIG_TYPE}" == *"singlestackv6"* ]]; then
    NET_ARGS+=" --fixed-ip subnet=${CONTROL_PLANE_SUBNET_V6}"
fi

API_VIPS_PORT_FIXED_IPS="$(openstack port create $NET_ARGS ${CLUSTER_NAME}-${CONFIG_TYPE}-api -f json)"
mapfile API_VIPS < <(echo -e $API_VIPS_PORT_FIXED_IPS  | jq  -rM .fixed_ips[].ip_address)
>&2 echo "Created port ${CLUSTER_NAME}-${CONFIG_TYPE}-api: ${API_VIPS[*]}"

INGRESS_VIPS_PORT_FIXED_IPS="$(openstack port create $NET_ARGS ${CLUSTER_NAME}-${CONFIG_TYPE}-ingress -f json)"
mapfile INGRESS_VIPS < <(echo -e $INGRESS_VIPS_PORT_FIXED_IPS  | jq  -rM .fixed_ips[].ip_address)
>&2 echo "Created port ${CLUSTER_NAME}-${CONFIG_TYPE}-ingress: ${INGRESS_VIPS[*]}"

echo "API_VIPS=( ${API_VIPS[*]} )" > ${SHARED_DIR}/VIPS
echo "INGRESS_VIPS=( ${INGRESS_VIPS[*]} )" >> ${SHARED_DIR}/VIPS
# Get only the first VIP for API an Ingress to populate the dns records
echo "${API_VIPS[0]}" > ${SHARED_DIR}/API_IP
echo "${INGRESS_VIPS[0]}" > ${SHARED_DIR}/INGRESS_IP
