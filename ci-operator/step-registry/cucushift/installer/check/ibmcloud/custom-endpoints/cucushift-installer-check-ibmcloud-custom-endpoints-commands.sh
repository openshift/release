#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"
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

function get_service_endpoint() {
    local service_name=$1
    local service_endpoint=$2
    if [[ "$service_endpoint" == "DEFAULT_ENDPOINT" ]]; then
        service_endpoint=$(jq -r --arg s "${service_name}" '.[$s] // ""' "${DEFAULT_PRIVATE_ENDPOINTS}")
    fi
    echo "${service_endpoint}"
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ret=0
if [ -n "$SERVICE_ENDPOINT_COS" ]; then
    service_endpoint=$(get_service_endpoint "COS" $SERVICE_ENDPOINT_COS)
    image_registry_pod=$(oc -n openshift-image-registry get pod -l docker-registry=default --no-headers | awk '{print $1}' | head -1)
    output_from_pod=$(oc -n openshift-image-registry exec ${image_registry_pod} -- env | grep  "REGISTRY_STORAGE_S3_REGIONENDPOINT")
    eval "${output_from_pod}"
    if [[ "$service_endpoint" != "$REGISTRY_STORAGE_S3_REGIONENDPOINT" ]]; then
        echo "ERROR: COS custom endpoint - ${service_endpoint} does not take effect in image-registry deployment - ${REGISTRY_STORAGE_S3_REGIONENDPOINT} !!!"
        ret=$((ret + 1))
    else
        echo "COS custom endpoint check passed"
    fi
else
    echo "WARN: No custom endpoint is defined for COS!"    
fi

exit $ret
