#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml

if [ ${IPVERSION} != 4 ]; then
    echo "IP version: ${IPVERSION} Not supported"
    exit 1
fi

if [ ${IPVERSION} == 4 ]; then

    CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
    read -r NETWORK MASK <<<"${SUBNETRANGE//// }"
    IFS='.' read -ra OCTATES <<<"$NETWORK"



    rm -rf ${SHARED_DIR}/ADDITIONALNETWORKIDS
    rm -rf ${SHARED_DIR}/ADDITIONALSUBNETIDS
    for i in $(seq 1 ${NETWORKCOUNT}); do
      NC=$((${OCTATES[2]} + i -1 ))
      CIDR=${OCTATES[0]}.${OCTATES[1]}.${NC}.0/${MASK}

      NETWORK_ID=$(openstack network create $CLUSTER_NAME.${i}  --format value -c 'id' )
      echo ${NETWORK_ID} >> ${SHARED_DIR}/ADDITIONALNETWORKIDS

      SUBNET_ID=$(openstack subnet create --network ${NETWORK_ID} --subnet-range $CIDR $CLUSTER_NAME.${i} --format value -c 'id' )
      echo ${SUBNET_ID} >> ${SHARED_DIR}/ADDITIONALSUBNETIDS
    done
fi