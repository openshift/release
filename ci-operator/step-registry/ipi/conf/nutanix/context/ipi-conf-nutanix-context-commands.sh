#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Failed to acquire lease"
    exit 1
fi

if [[ -f ${CLUSTER_PROFILE_DIR}/secrets.sh ]]; then
  NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
else
  NUTANIX_AUTH_PATH=/var/run/vault/nutanix/secrets.sh
fi

declare prism_central_host
declare prism_central_port
declare prism_central_username
declare prism_central_password
declare prism_element_host
declare prism_element_port
declare prism_element_username
declare prism_element_password
declare prism_element_storage_container
declare override_rhcos_image
declare one_net_mode_network_name
declare awk_ip_program
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
# For QE nutanix with multi zone, we need to select PE by host IP
if [[ $LEASED_RESOURCE =~ "nutanix-qe" ]]; then
    pe_uuid=$(echo "${clusters_json}" | jq ".entities[] | select (.spec.resources.network.external_ip == \"${prism_element_host}\") | .metadata.uuid" | head -n 1)
else
    pe_uuid=$(echo "${clusters_json}" | jq '.entities[] | select (.spec.name != "Unnamed") | .metadata.uuid' | head -n 1)
fi

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
slice_number=${LEASED_RESOURCE: -1}

if [[ ! -z "${one_net_mode_network_name:-}" ]]; then
  subnet_name="${one_net_mode_network_name}"
fi

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
  RANDOM_API_VIP_BLOCK=$(( RANDOM % 254 ))
  API_VIP=$(echo "${subnet_ip}" | sed 's/"//g' | awk -v random=${RANDOM_API_VIP_BLOCK} -F. '{printf "%d.%d.%d.%d", $1, $2, $3, random}')

  if [[ ! -z  "${awk_ip_program}" ]]; then
    API_VIP=$(echo "${subnet_ip}" | sed 's/"//g' | awk -F. -v num=${slice_number} -v type="api" "${awk_ip_program}")
  fi
fi

if [[ -z "${INGRESS_VIP}" ]]; then
  if [[ -z "${subnet_ip}" ]]; then
    echo "$(date -u --rfc-3399=seconds) - Cannot get VIP for Ingress"
    exit 1
  fi
  RANDOM_INGRESS_VIP_BLOCK=$(( RANDOM % 254 ))
  INGRESS_VIP=$(echo "${subnet_ip}" | sed 's/"//g' | awk -v random=${RANDOM_INGRESS_VIP_BLOCK} -F. '{printf "%d.%d.%d.%d", $1, $2, $3, random}')

  if [[ ! -z  "${awk_ip_program}" ]]; then
    INGRESS_VIP=$(echo "${subnet_ip}" | sed 's/"//g' | awk -F. -v num=${slice_number} -v type="ingress" "${awk_ip_program}")
  fi
fi

echo "$(date -u --rfc-3339=seconds) - Creating nutanix_context.sh file..."
cat > "${SHARED_DIR}/nutanix_context.sh" << EOF
export NUTANIX_HOST='${prism_central_host}'
export NUTANIX_PORT='${prism_central_port}'
export NUTANIX_USERNAME='${prism_central_username}'
export NUTANIX_PASSWORD='${prism_central_password}'
export PE_HOST='${prism_element_host}'
export PE_PORT='${prism_element_port}'
export PE_USERNAME='${prism_element_username}'
export PE_PASSWORD='${prism_element_password}'
export PE_UUID='${pe_uuid}'
export PE_STORAGE_CONTAINER='${prism_element_storage_container}'
export SUBNET_UUID='${subnet_uuid}'
export API_VIP='${API_VIP}'
export INGRESS_VIP='${INGRESS_VIP}'
export OVERRIDE_RHCOS_IMAGE='${override_rhcos_image:-}'
EOF
