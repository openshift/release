#!/bin/bash

REGION="${LEASED_RESOURCE}"
CONFIG="${SHARED_DIR}/install-config.yaml"
DEFAULT_PRIVATE_ENDPOINTS=$(mktemp)
cat > "${DEFAULT_PRIVATE_ENDPOINTS}" << EOF
{
    "IAM": "https://private.iam.cloud.ibm.com",
    "VPC": "https://${REGION}.private.iaas.cloud.ibm.com/v1",
    "ResourceController": "https://private.resource-controller.cloud.ibm.com",
    "ResourceManager": "https://private.resource-controller.cloud.ibm.com",
    "DNSServices": "https://api.private.dns-svcs.cloud.ibm.com/v1",
    "COS": "https://s3.direct.${REGION}.cloud-object-storage.appdomain.cloud",
    "GlobalSearch": "https://api.private.global-search-tagging.cloud.ibm.com",
    "GlobalTagging": "https://tags.private.global-search-tagging.cloud.ibm.com"
}
EOF

function patch_endpoint()
{
  local service_name=$1
  local service_endpoint=$2
  local config_patch="${SHARED_DIR}/install-config-${service_name}.yaml.patch"
  if [[ "$service_endpoint" == "DEFAULT_ENDPOINT" ]]; then
    service_endpoint=$(jq -r --arg s "${service_name}" '.[$s] // ""' "${DEFAULT_PRIVATE_ENDPOINTS}")
  fi
  cat > "${config_patch}" << EOF
platform:
  ibmcloud:
    serviceEndpoints:
    - name: ${service_name}
      url: ${service_endpoint}
EOF
  echo "Adding custom endpoint $service_name $service_endpoint"
  yq-go m -a -x -i "${CONFIG}" "${config_patch}"
}

if [ -n "$SERVICE_ENDPOINT_IAM" ]; then
  patch_endpoint "IAM" $SERVICE_ENDPOINT_IAM
fi
if [ -n "$SERVICE_ENDPOINT_VPC" ]; then
  patch_endpoint "VPC" $SERVICE_ENDPOINT_VPC
fi
if [ -n "$SERVICE_ENDPOINT_ResourceController" ]; then
  patch_endpoint "ResourceController" $SERVICE_ENDPOINT_ResourceController
fi
if [ -n "$SERVICE_ENDPOINT_ResourceManager" ]; then
  patch_endpoint "ResourceManager" $SERVICE_ENDPOINT_ResourceManager
fi
if [ -n "$SERVICE_ENDPOINT_DNSServices" ]; then
  patch_endpoint "DNSServices" $SERVICE_ENDPOINT_DNSServices
fi
if [ -n "$SERVICE_ENDPOINT_COS" ]; then
  patch_endpoint "COS" $SERVICE_ENDPOINT_COS
fi
if [ -n "$SERVICE_ENDPOINT_GlobalSearch" ]; then
  patch_endpoint "GlobalSearch" $SERVICE_ENDPOINT_GlobalSearch
fi
if [ -n "$SERVICE_ENDPOINT_GlobalTagging" ]; then
  patch_endpoint "GlobalTagging" $SERVICE_ENDPOINT_GlobalTagging
fi
