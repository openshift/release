#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

BOOTSTRAP_FIP_AND_ID=$(openstack floating ip create --description "$CLUSTER_NAME".bootstrap-fip "$OPENSTACK_EXTERNAL_NETWORK" --format value -c 'floating_ip_address' -c 'id')
echo "${BOOTSTRAP_FIP_AND_ID}" |awk 'NR==1' > "${SHARED_DIR}"/BOOTSTRAP_FIP_IP
echo "${BOOTSTRAP_FIP_AND_ID}" |awk 'NR==2' > "${SHARED_DIR}"/BOOTSTRAP_FIP_UID
#Mark the fip for deletion
echo "${BOOTSTRAP_FIP_AND_ID}" |awk 'NR==2' >> ${SHARED_DIR}/DELETE_FIPS
cp "${SHARED_DIR}"/DELETE_FIPS ${ARTIFACT_DIR}
