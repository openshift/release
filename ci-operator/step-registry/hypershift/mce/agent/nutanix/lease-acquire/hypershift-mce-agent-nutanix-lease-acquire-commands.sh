#!/bin/bash

set -euo pipefail

source "${LEASE_PROXY_CLIENT_SH}"

if [[ -z "${LEASE_PROXY_SERVER_URL:-}" ]]; then
  echo "LEASE_PROXY_SERVER_URL is required to acquire the Nutanix quota-slice lease."
  exit 1
fi

if [[ -s "${SHARED_DIR}/nutanix_lease_resource" ]]; then
  echo "A Nutanix lease is already recorded for this run."
  exit 1
fi

lease_handle=$(lease__acquire --type=nutanix-quota-slice --scope=step)
lease_recorded=false
function release_unrecorded_lease() {
  if [[ "${lease_recorded}" != "true" && -n "${lease_handle:-}" ]]; then
    lease__release --handle="${lease_handle}" || true
  fi
  rm -f "${lease_handle:-}" "${lease_handle:-}.lock"
}
trap release_unrecorded_lease EXIT
lease_resource=$(lease__cat --handle="${lease_handle}" --format=plain)

if [[ ! "${lease_resource}" =~ ^nutanix-segment-[0-9]+$ ]]; then
  echo "The Nutanix lease returned an unexpected resource name: ${lease_resource}"
  lease__release --handle="${lease_handle}" || true
  exit 1
fi

printf '%s\n' "${lease_resource}" > "${SHARED_DIR}/nutanix_lease_resource"
chmod 600 "${SHARED_DIR}/nutanix_lease_resource"
lease_recorded=true

auth_file=/var/run/vault/nutanix/secrets.sh
if [[ ! -r "${auth_file}" ]]; then
  echo "The Nutanix Prism credentials are not mounted at ${auth_file}."
  exit 1
fi

set +x
declare prism_central_host prism_central_port prism_central_username prism_central_password
declare prism_element_host prism_element_port prism_element_username prism_element_password
declare prism_element_storage_container
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
subnet_json=$(jq -ce --arg name "${lease_resource}" '[.entities[] | select(.spec.name == $name)] | if length == 1 then .[0] else error("Leased subnet is missing or ambiguous") end' <<<"${subnets_json}")
subnet_uuid=$(jq -er '.metadata.uuid' <<<"${subnet_json}")
subnet_ip=$(jq -r '.spec.resources.ip_config.subnet_ip // empty' <<<"${subnet_json}")

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
printf 'export SUBNET_NAME=%q\n' "${lease_resource}" >> "${context_tmp}"
printf 'export SUBNET_IP=%q\n' "${subnet_ip}" >> "${context_tmp}"
printf 'export NUTANIX_PC_URL=%q\n' "${pc_url}" >> "${context_tmp}"
printf 'export NUTANIX_LEASED_RESOURCE=%q\n' "${lease_resource}" >> "${context_tmp}"
chmod 600 "${context_tmp}"
mv "${context_tmp}" "${SHARED_DIR}/nutanix_context.sh"

printf 'Nutanix lease: %s\nPrism Element: %s (%s)\nLeased subnet: %s (%s)\n' \
  "${lease_resource}" "${pe_name}" "${pe_uuid}" "${lease_resource}" "${subnet_uuid}"
