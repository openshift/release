#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Failed to acquire lease"
    exit 1
fi

NUTANIX_AUTH_PATH=/var/run/vault/nutanix/secrets.sh

declare prism_central_host
declare prism_central_port
declare prism_central_username
declare prism_central_password
# shellcheck source=/dev/random
source "${NUTANIX_AUTH_PATH}"

echo "$(date -u --rfc-3339=seconds) - Getting PE UUID"

pc_url="https://${prism_central_host}:${prism_central_port}"
api_ep="${pc_url}/api/nutanix/v3/clusters/list"
un="${prism_central_username}"
pw="${prism_central_password}"
data="{
  \"kind\": \"cluster\"
}"

clusters_json=$(curl -ks -u "${un}":"${pw}" -X POST ${api_ep} -H "Content-Type: application/json" -d @-<<<"${data}")
pe_uuid=$(echo "${clusters_json}" | jq '.entities[] | select (.spec.name != "Unnamed") | .metadata.uuid' | head -n 1)

if [[ -z "${pe_uuid}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Cannot get PE UUID"
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - PE UUID: ${pe_uuid}"

echo "$(date -u --rfc-3339=seconds) - Getting Subnet UUID"
api_ep="${pc_url}/api/nutanix/v3/subnets/list"
data="{
  \"kind\": \"subnet\"
}"
subnet_name="${LEASED_RESOURCE}"

subnets_json=$(curl -ks -u "${un}":"${pw}" -X POST ${api_ep} -H "Content-Type: application/json" -d @-<<<"${data}")
subnet_uuid=$(echo "${subnets_json}" | jq ".entities[] | select (.spec.name == \"${subnet_name}\") | .metadata.uuid ")

if [[ -z "${subnet_uuid}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Cannot get Subnet UUID"
  exit 1
fi

subnet_ip=$(echo "${subnets_json}" | jq ".entities[] | select(.spec.name==\"${subnet_name}\") | .spec.resources.ip_config.subnet_ip")

if [[ -z "${API_VIP}" ]]; then
  if [[ -z "${subnet_ip}" ]]; then
    echo "$(date -u --rfc-3399=seconds) - Cannot get VIP for API"
    exit 1
  fi
  API_VIP=$(echo "${subnet_ip}" | sed 's/"//g' | awk -F. '{printf "%d.%d.%d.2", $1, $2, $3}')
fi

if [[ -z "${INGRESS_VIP}" ]]; then
  if [[ -z "${subnet_ip}" ]]; then
    echo "$(date -u --rfc-3399=seconds) - Cannot get VIP for Ingress"
    exit 1
  fi
  INGRESS_VIP=$(echo "${subnet_ip}" | sed 's/"//g' | awk -F. '{printf "%d.%d.%d.3", $1, $2, $3}')
fi

echo "$(date -u --rfc-3339=seconds) - Creating nutanix_context.sh file..."
cat > "${SHARED_DIR}/nutanix_context.sh" << EOF
export NUTANIX_HOST=${prism_central_host}
export NUTANIX_PORT=${prism_central_port}
export NUTANIX_USERNAME=${prism_central_username}
export NUTANIX_PASSWORD=${prism_central_password}
export PE_UUID=${pe_uuid}
export SUBNET_UUID=${subnet_uuid}
export API_VIP=${API_VIP}
export INGRESS_VIP=${INGRESS_VIP}
EOF
