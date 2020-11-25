#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)


LB_FIP_AND_ID=$(openstack floating ip create --description $CLUSTER_NAME.api-fip $OPENSTACK_EXTERNAL_NETWORK --format value -c 'floating_ip_address' -c 'id')
echo ${LB_FIP_AND_ID} |awk '{print $1}' > ${SHARED_DIR}/LB_FIP_IP
echo ${LB_FIP_AND_ID} |awk '{print $2}' > ${SHARED_DIR}/LB_FIP_UID
cp ${SHARED_DIR}/LB_FIP_IP ${ARTIFACT_DIR}
cp ${SHARED_DIR}/LB_FIP_UID ${ARTIFACT_DIR}
#Mark the fip for deletion
echo ${LB_FIP_AND_ID} |awk '{print $2}' >> ${SHARED_DIR}/DELETE_FIPS
cp ${SHARED_DIR}/DELETE_FIPS ${ARTIFACT_DIR}

INGRESS_FIP_AND_ID=$(openstack floating ip create --description ${CLUSTER_NAME}.ingress-fip ${OPENSTACK_EXTERNAL_NETWORK} --format value -c 'floating_ip_address' -c 'id')
echo ${INGRESS_FIP_AND_ID} |awk '{print $1}' > ${SHARED_DIR}/INGRESS_FIP_IP
echo ${INGRESS_FIP_AND_ID} |awk '{print $2}' > ${SHARED_DIR}/INGRESS_FIP_UID
cp ${SHARED_DIR}/INGRESS_FIP_IP ${ARTIFACT_DIR}
cp ${SHARED_DIR}/INGRESS_FIP_UID ${ARTIFACT_DIR}
#Mark the fip for deletion
echo ${INGRESS_FIP_AND_ID} |awk '{print $2}' >> ${SHARED_DIR}/DELETE_FIPS
cp ${SHARED_DIR}/DELETE_FIPS ${ARTIFACT_DIR}
