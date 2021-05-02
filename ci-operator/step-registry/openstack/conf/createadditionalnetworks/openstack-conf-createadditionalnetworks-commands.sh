#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
read NETWORK MASK <<<"${SUBNET_RANGE//// }"
IFS='.' read -ra OCTATES <<<"$NETWORK"



rm -rf ${SHARED_DIR}/ADDITIONAL_NETWORK_IDS
rm -rf ${SHARED_DIR}/ADDITIONAL_SUBNET_IDS
for i in $(seq 1 ${NUMBER_OF_ADDITIONAL_NETWORKS}); do
  NC=$((${OCTATES[2]} + i -1 ))
  CIDR=${OCTATES[0]}.${OCTATES[1]}.${NC}.0/${MASK}

  NETWORK_ID=$(openstack network create $CLUSTER_NAME.additionalnetwork.${i}  --format value -c 'id' )
  echo ${NETWORK_ID} >> ${SHARED_DIR}/ADDITIONAL_NETWORK_IDS

  SUBNET_ID=$(openstack subnet create --network ${NETWORK_ID} --subnet-range $CIDR $CLUSTER_NAME.additionalnetwork.${i} --format value -c 'id' )
  echo ${SUBNET_ID} >> ${SHARED_DIR}/ADDITIONAL_SUBNET_IDS
done