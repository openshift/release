#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
echo "Azure region: ${LEASED_RESOURCE}"

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
cloud_name=${LEASED_RESOURCE}
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
    baseDomainResourceGroupName: ${BASE_DOMAIN_RESOURCE_GROUP_NAME}
    region: ${LEASED_RESOURCE}
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
APP_ID=$(jq -r .clientId "${SHARED_DIR}/osServicePrincipal.json")
AAD_CLIENT_SECRET=$(jq -r .clientSecret ${SHARED_DIR}/osServicePrincipal.json)
TENANT_ID=$(jq -r .tenantId "${SHARED_DIR}/osServicePrincipal.json")
cat >> "${SHARED_DIR}/azurestack-login-script.sh" << EOF

if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
    cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
    if ls /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem > /dev/null 2>&1; then
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
    elif ls /go/src/github.com/openshift/installer/azure-cli/lib64/python*/site-packages/certifi/cacert.pem > /dev/null 2>&1; then
        cat /go/src/github.com/openshift/installer/azure-cli/lib64/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
    else
        echo "ERROR: unable to find cacert.pem in pyhton library that azure-cli depends on, exit..."
        exit 1
    fi
    export REQUESTS_CA_BUNDLE=/tmp/ca.pem
fi
az cloud register \
    -n ${cloud_name} \
    --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
    --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
az cloud set -n ${cloud_name}
az cloud update --profile 2019-03-01-hybrid
az login --service-principal -u "$APP_ID" -p "$AAD_CLIENT_SECRET" --tenant "$TENANT_ID" > /dev/null
EOF

chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
