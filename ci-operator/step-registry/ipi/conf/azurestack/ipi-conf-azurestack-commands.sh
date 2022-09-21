#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
REGION="ppe3"
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

cat >> "${CONFIG}" << EOF
baseDomain: ppe.azurestack.devcluster.openshift.com
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