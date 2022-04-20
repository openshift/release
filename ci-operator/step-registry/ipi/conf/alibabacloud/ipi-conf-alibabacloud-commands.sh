#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# copy the creds to the SHARED_DIR
cp /var/run/vault/alibaba/alibabacreds.ini ${SHARED_DIR}
cp /var/run/vault/alibaba/config ${SHARED_DIR}
cp /var/run/vault/alibaba/envvars ${SHARED_DIR}

source /var/run/vault/alibaba/envvars
echo -e "\n=========content of ${SHARED_DIR}/config============\n"
base64 -w0 "${SHARED_DIR}/config"
echo -e "\n=========content of ${SHARED_DIR}/envvars============\n"
base64 -w0 "${SHARED_DIR}/envvars"
echo -e "\n=========ls SHARED_DIR============\n"
ls -l "${SHARED_DIR}"
echo -e "\n=====================\n"

CONFIG="${SHARED_DIR}/install-config.yaml"

REGION="${LEASED_RESOURCE}"
echo "Alibaba region: ${REGION}"

cat >> "${CONFIG}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  alibabacloud:
    region: ${REGION}
    resourceGroupID: ${CI_RESOURCE_GROUP_ID}
EOF
