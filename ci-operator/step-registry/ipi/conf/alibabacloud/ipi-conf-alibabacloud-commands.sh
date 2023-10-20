#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# copy the creds to the SHARED_DIR
if test -f "${CLUSTER_PROFILE_DIR}/alibabacreds.ini" 
then
  echo "Copying creds from CLUSTER_PROFILE_DIR to SHARED_DIR..."
  cp ${CLUSTER_PROFILE_DIR}/alibabacreds.ini ${SHARED_DIR}
  cp ${CLUSTER_PROFILE_DIR}/config ${SHARED_DIR}
  cp ${CLUSTER_PROFILE_DIR}/envvars ${SHARED_DIR}
else
  echo "Copying creds from /var/run/vault/alibaba/ to SHARED_DIR..."
  cp /var/run/vault/alibaba/alibabacreds.ini ${SHARED_DIR}
  cp /var/run/vault/alibaba/config ${SHARED_DIR}
  cp /var/run/vault/alibaba/envvars ${SHARED_DIR}
fi

source ${SHARED_DIR}/envvars

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "Alibaba base domain: ${BASE_DOMAIN}"
REGION="${LEASED_RESOURCE}"
echo "Alibaba region: ${REGION}"
INSTANCE_TYPE=ecs.g6.2xlarge
echo "Alibaba instance type: ${INSTANCE_TYPE}"

cat >> "${CONFIG}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  alibabacloud:
    region: ${REGION}
    resourceGroupID: ${CI_RESOURCE_GROUP_ID}
controlPlane:  
  name: master
  platform:
    alibabacloud:
      instanceType: ${INSTANCE_TYPE}
compute:
- name: worker  
  platform:
    alibabacloud:
      instanceType: ${INSTANCE_TYPE}    
EOF
