#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
REGION="${LEASED_RESOURCE}"
echo "Azure region: ${REGION}"

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
  workers=0
fi
master_type=null
if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
  master_type=Standard_D32_v3
elif [[ "${SIZE_VARIANT}" == "large" ]]; then
  master_type=Standard_D16_v3
elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
  master_type=Standard_D8_v3
fi
echo $master_type

ENDPOINT="${AZURESTACK_ENDPOINT}"
echo "ASH ARM Endpoint: ${ENDPOINT}"

cp "/var/run/azurestack-cluster-secrets/service-principal" "${SHARED_DIR}/osServicePrincipal.json"
if [[ -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]]; then
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")
    if [[ "${cloud_name}" == "WWT" ]]; then
      cp "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json" "${SHARED_DIR}/osServicePrincipal.json"
    fi
fi

BASE_DOMAIN="ppe.azurestack.devcluster.openshift.com"
if [[ -f "${CLUSTER_PROFILE_DIR}/public_hosted_zone" ]]; then
  BASE_DOMAIN=$(< "${CLUSTER_PROFILE_DIR}/public_hosted_zone")
fi

cat >> "${CONFIG}" << EOF
baseDomain: ${BASE_DOMAIN}
credentialsMode: Manual
platform:
  azure:
    baseDomainResourceGroupName: openshiftInstallerRG
    region: ${REGION}
    cloudName: AzureStackCloud
    armEndpoint: ${ENDPOINT}
controlPlane:
  name: master
compute:
- name: worker
  replicas: ${workers}
EOF

echo "${AZURESTACK_ENDPOINT}" >> ${SHARED_DIR}/AZURESTACK_ENDPOINT
echo "${SUFFIX_ENDPOINT}" >> ${SHARED_DIR}/SUFFIX_ENDPOINT
