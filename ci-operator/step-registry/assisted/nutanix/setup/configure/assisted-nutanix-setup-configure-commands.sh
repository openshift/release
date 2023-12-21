#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ nutanix assisted test-infra setup machine command ************"

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

# shellcheck source=/dev/random
source $SHARED_DIR/nutanix_context.sh

echo "$(date -u --rfc-3339=seconds) - Getting PE Name"

pc_url="https://${PE_HOST}:${PE_PORT}"
clusters_api_ep="${pc_url}/api/nutanix/v3/clusters/list"
un="${NUTANIX_USERNAME}"
pw="${NUTANIX_PASSWORD}"
data="{
  \"kind\": \"cluster\"
}"

clusters_json=$(curl -ks -u "${un}":"${pw}" -X POST ${clusters_api_ep} -H "Content-Type: application/json" -d @-<<<"${data}")
pe_name=$(echo "${clusters_json}" | jq -r '.entities[] | select (.spec.name != "Unnamed") | .spec.name' | head -n 1)

if [[ -z "${pe_name}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Cannot get PE Name"
    exit 1
fi

subnets_api_ep="${pc_url}/api/nutanix/v3/subnets/list"
data="{
  \"kind\": \"subnet\"
}"
subnets_json=$(curl -ks -u "${un}":"${pw}" -X POST ${subnets_api_ep} -H "Content-Type: application/json" -d @-<<<"${data}")
subnet_name=$(echo "${subnets_json}" | jq -r ".entities[] | select (.metadata.uuid == ${SUBNET_UUID}) | .spec.name")

echo "$(date -u --rfc-3339=seconds) - PE Name: ${pe_name}"
echo "$(date -u --rfc-3339=seconds) - Subnet Name: ${subnet_name}"

base_domain=$(<"${SHARED_DIR}"/basedomain.txt)

# Create variables file
cat >> "${SHARED_DIR}"/platform-conf.sh << EOF
export PLATFORM=nutanix
export VIP_DHCP_ALLOCATION=false
export NUTANIX_USERNAME='${NUTANIX_USERNAME}'
export NUTANIX_PASSWORD='${NUTANIX_PASSWORD}'
export NUTANIX_ENDPOINT='${NUTANIX_HOST}'
export NUTANIX_PORT="${NUTANIX_PORT}"
export NUTANIX_CLUSTER_NAME="${pe_name}"
export NUTANIX_SUBNET_NAME="${subnet_name}"
export API_VIPS="[{\"ip\": \"${API_VIP}\"}]"
export INGRESS_VIPS="[{\"ip\": \"${INGRESS_VIP}\"}]"
export BASE_DOMAIN="${base_domain}"
export CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
EOF
