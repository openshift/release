#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)

SECURITY_GROUP_ID=$(openstack security group create ${CLUSTER_NAME}-ssh -c ID -f value)
openstack security group rule create --protocol tcp --dst-port 22:22 ${SECURITY_GROUP_ID}
echo SECURITY_GROUP_ID >> ${SHARED_DIR}/ADDITIONALSECURITYGROUPIDS