#!/bin/bash

set -euo pipefail

if [[ "${IP_STACK:-v4}" != "v4" ]]; then
  echo "The Nutanix Agent worker flow currently supports IPv4 only."
  exit 1
fi

if [[ -z "${NUTANIX_QUOTA_SLICE:-}" ]]; then
  echo "NUTANIX_QUOTA_SLICE is required from the workflow lease."
  exit 1
fi

lease_resource=${NUTANIX_QUOTA_SLICE}

auth_file=/var/run/vault/nutanix/secrets.sh
if [[ ! -r "${auth_file}" ]]; then
  echo "The Nutanix Prism credentials are not mounted at ${auth_file}."
  exit 1
fi

set +x
declare prism_central_host prism_central_port prism_central_username prism_central_password
declare prism_element_host prism_element_port prism_element_username prism_element_password
declare prism_element_storage_container one_net_mode_network_name awk_ip_program
# shellcheck source=/dev/null
source "${auth_file}"

for variable in prism_central_host prism_central_port prism_central_username prism_central_password prism_element_host prism_element_port prism_element_username prism_element_password prism_element_storage_container; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Required Nutanix credential field ${variable} is empty."
    exit 1
  fi
done

pc_url="https://${prism_central_host}:${prism_central_port}"
clusters_json=$(curl --silent --show-error --fail --insecure --user "${prism_central_username}:${prism_central_password}" \
  -H 'Content-Type: application/json' -X POST "${pc_url}/api/nutanix/v3/clusters/list" \
  --data '{"kind":"cluster"}')
pe_json=$(jq -ce --arg host "${prism_element_host}" '[.entities[] | select(.spec.resources.network.external_ip == $host)] | if length == 1 then .[0] else error("Prism Element cluster is missing or ambiguous") end' <<<"${clusters_json}")
pe_uuid=$(jq -er '.metadata.uuid' <<<"${pe_json}")
pe_name=$(jq -er '.spec.name' <<<"${pe_json}")

subnets_json=$(curl --silent --show-error --fail --insecure --user "${prism_central_username}:${prism_central_password}" \
  -H 'Content-Type: application/json' -X POST "${pc_url}/api/nutanix/v3/subnets/list" \
  --data '{"kind":"subnet"}')
subnet_name=${one_net_mode_network_name:-$lease_resource}
subnet_json=$(jq -ce --arg name "${subnet_name}" '[.entities[] | select(.spec.name == $name)] | if length == 1 then .[0] else error("Selected subnet is missing or ambiguous") end' <<<"${subnets_json}")
subnet_uuid=$(jq -er '.metadata.uuid' <<<"${subnet_json}")
subnet_ip=$(jq -r '.spec.resources.ip_config.subnet_ip // empty' <<<"${subnet_json}")
if [[ -z "${subnet_ip}" || -z "${awk_ip_program:-}" ]]; then
  echo "A subnet IP and the Nutanix ingress VIP allocation rule are required."
  exit 1
fi
slice_number=${lease_resource##*-}
ingress_vip=$(awk -F. -v num="${slice_number}" -v type=ingress "${awk_ip_program}" <<<"${subnet_ip}")
if [[ ! "${ingress_vip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || ! awk -F. '{ exit !($1 < 256 && $2 < 256 && $3 < 256 && $4 < 256) }' <<<"${ingress_vip}"; then
  echo "The Nutanix ingress VIP allocation rule returned an invalid IPv4 address."
  exit 1
fi

context_tmp="${SHARED_DIR}/nutanix_context.sh.tmp"
umask 077
printf 'export NUTANIX_HOST=%q\n' "${prism_central_host}" > "${context_tmp}"
printf 'export NUTANIX_PORT=%q\n' "${prism_central_port}" >> "${context_tmp}"
printf 'export NUTANIX_USERNAME=%q\n' "${prism_central_username}" >> "${context_tmp}"
printf 'export NUTANIX_PASSWORD=%q\n' "${prism_central_password}" >> "${context_tmp}"
printf 'export PE_HOST=%q\n' "${prism_element_host}" >> "${context_tmp}"
printf 'export PE_PORT=%q\n' "${prism_element_port}" >> "${context_tmp}"
printf 'export PE_USERNAME=%q\n' "${prism_element_username}" >> "${context_tmp}"
printf 'export PE_PASSWORD=%q\n' "${prism_element_password}" >> "${context_tmp}"
printf 'export PE_UUID=%q\n' "${pe_uuid}" >> "${context_tmp}"
printf 'export PE_NAME=%q\n' "${pe_name}" >> "${context_tmp}"
printf 'export PE_STORAGE_CONTAINER=%q\n' "${prism_element_storage_container}" >> "${context_tmp}"
printf 'export SUBNET_UUID=%q\n' "${subnet_uuid}" >> "${context_tmp}"
printf 'export SUBNET_NAME=%q\n' "${subnet_name}" >> "${context_tmp}"
printf 'export SUBNET_IP=%q\n' "${subnet_ip}" >> "${context_tmp}"
printf 'export INGRESS_VIP=%q\n' "${ingress_vip}" >> "${context_tmp}"
printf 'export NUTANIX_PC_URL=%q\n' "${pc_url}" >> "${context_tmp}"
chmod 600 "${context_tmp}"
mv "${context_tmp}" "${SHARED_DIR}/nutanix_context.sh"

printf 'Nutanix quota slice: %s\nPrism Element: %s (%s)\nSelected subnet: %s (%s)\nIngress VIP: %s\n' \
  "${lease_resource}" "${pe_name}" "${pe_uuid}" "${subnet_name}" "${subnet_uuid}" "${ingress_vip}"
