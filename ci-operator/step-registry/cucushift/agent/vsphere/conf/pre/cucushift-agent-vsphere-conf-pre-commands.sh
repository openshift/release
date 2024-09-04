#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Creating reusable variable files..."
# Create base-domain.txt
echo "vmc-ci.devcluster.openshift.com" >"${SHARED_DIR}"/base-domain.txt
base_domain=$(<"${SHARED_DIR}"/base-domain.txt)
# Create cluster-name.txt
echo "${NAMESPACE}-${UNIQUE_HASH}" >"${SHARED_DIR}"/cluster-name.txt
cluster_name=$(<"${SHARED_DIR}"/cluster-name.txt)
# Create cluster-domain.txt
echo "${cluster_name}.${base_domain}" >"${SHARED_DIR}"/cluster-domain.txt
cluster_domain=$(<"${SHARED_DIR}"/cluster-domain.txt)

# select a hardware version for testing
hw_versions=(15 17 18 19)
hw_available_versions=${#hw_versions[@]}
selected_hw_version_index=$((RANDOM % +hw_available_versions))
target_hw_version=${hw_versions[$selected_hw_version_index]}

echo "$(date -u --rfc-3339=seconds) - Selected hardware version ${target_hw_version}"

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
echo "export target_hw_version=${target_hw_version}" >>"${SHARED_DIR}"/vsphere_context.sh

SUBNETS_CONFIG=/var/run/vault/vsphere-ibmcloud-config/subnets.json
if [[ "${CLUSTER_PROFILE_NAME:-}" == "vsphere-elastic" ]]; then
    SUBNETS_CONFIG="${SHARED_DIR}/subnets.json"
fi
declare vlanid
declare primaryrouterhostname
source "${SHARED_DIR}/vsphere_context.sh"
# These two environment variables are coming from vsphere_context.sh and
# the file they are assigned to is not available in this step.
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
  echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
  exit 1
fi
if [ "${MASTERS}" -eq 1 ]; then
  jq -r --argjson N 4 --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}" >>"${SHARED_DIR}"/vips.txt
  jq -r --argjson N 4 --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}" >>"${SHARED_DIR}"/vips.txt
else
  jq -r --argjson N 2 --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}" >>"${SHARED_DIR}"/vips.txt
  jq -r --argjson N 3 --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}" >>"${SHARED_DIR}"/vips.txt
fi

cat >>"${SHARED_DIR}/network-config.txt" <<EOF
dns_server=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].dnsServer' "${SUBNETS_CONFIG}")
gateway=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].gateway' "${SUBNETS_CONFIG}")
gateway_ipv6=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].gatewayipv6' "${SUBNETS_CONFIG}")
cidr=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].cidr' "${SUBNETS_CONFIG}")
cidr_ipv6=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].CidrIPv6' "${SUBNETS_CONFIG}")
machine_cidr=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].machineNetworkCidr' "${SUBNETS_CONFIG}")
rendezvous_ip_address=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[4]' "${SUBNETS_CONFIG}")
EOF

total_host="$((MASTERS + WORKERS))"
declare -a hostnames=()
declare -a ipv4Addresses=()
declare -a ipv6Addresses=()
for ((i = 0; i < total_host; i++)); do
  if [ "${WORKERS}" -gt 0 ]; then
    hostnames+=("${cluster_name}-master-$i")
    hostnames+=("${cluster_name}-worker-$i")
  else
    hostnames+=("${cluster_name}-master-$i")
  fi
  ipv4Addresses+=("$(jq -r --argjson N $((i + 4)) --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")")
  ipv6Addresses+=("$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].StartIPv6Address' "${SUBNETS_CONFIG}" | sed "s/::.*$/::$((i + 6))/")")
done

echo "${hostnames[@]}" > "${SHARED_DIR}"/hostnames.txt
echo "${ipv4Addresses[@]}" > "${SHARED_DIR}"/ipv4Addresses.txt
echo "${ipv6Addresses[@]}" > "${SHARED_DIR}"/ipv6Addresses.txt

if [ -n "${ADDITIONAL_WORKERS_DAY2}" ]; then
  declare -a additional_worker_hostnames=()
  declare -a additional_worker_ipv4Addresses=()
  declare -a additional_worker_ipv6Addresses=()
  for ((i = 0; i < "${ADDITIONAL_WORKERS_DAY2}"; i++)); do
    additional_worker_hostnames+=("${cluster_name}-additional-worker-$i")
    additional_worker_ipv4Addresses+=("$(jq -r --argjson N $((i + 10)) --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")")
    additional_worker_ipv6Addresses+=("$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].StartIPv6Address' "${SUBNETS_CONFIG}" | sed "s/::.*$/::$((i + 12))/")")
  done
  echo "${additional_worker_hostnames[@]}" > "${SHARED_DIR}"/additional_worker_hostnames.txt
  echo "${additional_worker_ipv4Addresses[@]}" > "${SHARED_DIR}"/additional_worker_ipv4Addresses.txt
  echo "${additional_worker_ipv6Addresses[@]}" > "${SHARED_DIR}"/additional_worker_ipv6Addresses.txt
  declare -a all_hostnames=()
  declare -a all_ipv4Addresses=()
  declare -a all_ipv6Addresses=()
  all_hostnames=("${hostnames[@]}" "${additional_worker_hostnames[@]}")
  all_ipv4Addresses=("${ipv4Addresses[@]}" "${additional_worker_ipv4Addresses[@]}")
  all_ipv6Addresses=("${ipv6Addresses[@]}" "${additional_worker_ipv6Addresses[@]}")
fi

ROUTE53_CREATE_JSON='{"Comment": "Create public OpenShift DNS records for Nodes of VSphere ABI CI install", "Changes": []}'
ROUTE53_DELETE_JSON='{"Comment": "Delete public OpenShift DNS records for Nodes of VSphere ABI CI install", "Changes": []}'

# shellcheck disable=SC2016
DNS_RECORD='{
"Action": "${ACTION}",
"ResourceRecordSet": {
  "Name": "${NAME}",
  "Type": "${TYPE}",
  "TTL": 60,
  "ResourceRecords": [{"Value": "${VALUE}"}]
  }
}'

# Generate IPv4 DNS entries
for (( node=0; node < ${#all_hostnames[@]}; node++)); do
  echo "Creating IPv4 DNS entry for ${all_hostnames[$node]}"
  node_record=$(echo "${DNS_RECORD}" |
    jq -r --arg ACTION "CREATE" \
          --arg CLUSTER_NAME "$cluster_name" \
          --arg VM_NAME "${all_hostnames[$node]}" \
          --arg CLUSTER_DOMAIN "${cluster_domain}" \
          --arg TYPE "A" \
          --arg IP_ADDRESS "${all_ipv4Addresses[$node]}" \
          '.Action = $ACTION |
           .ResourceRecordSet.Name = $CLUSTER_NAME+"-"+$VM_NAME+"."+$CLUSTER_DOMAIN+"." |
           .ResourceRecordSet.Type = $TYPE |
           .ResourceRecordSet.ResourceRecords[0].Value = $IP_ADDRESS')
  ROUTE53_CREATE_JSON=$(echo "${ROUTE53_CREATE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
  node_record=$(echo "${node_record}" |
    jq -r --arg ACTION "DELETE" '.Action = $ACTION')
  ROUTE53_DELETE_JSON=$(echo "${ROUTE53_DELETE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
done
# Generate IPv6 DNS entries
if [[ $IP_FAMILIES == *IPv6* ]]; then
  for (( node=0; node < ${#all_hostnames[@]}; node++)); do
    echo "Creating IPv6 DNS entry for ${all_hostnames[$node]}"
    node_record=$(echo "${DNS_RECORD}" |
      jq -r --arg ACTION "CREATE" \
            --arg CLUSTER_NAME "$cluster_name" \
            --arg VM_NAME "${all_hostnames[$node]}" \
            --arg TYPE "AAAA" \
            --arg CLUSTER_DOMAIN "${cluster_domain}" \
            --arg IP_ADDRESS "${all_ipv6Addresses[$node]}" \
            '.Action = $ACTION |
             .ResourceRecordSet.Name = $CLUSTER_NAME+"-"+$VM_NAME+"."+$CLUSTER_DOMAIN+"." |
             .ResourceRecordSet.Type = $TYPE |
             .ResourceRecordSet.ResourceRecords[0].Value = $IP_ADDRESS')
    ROUTE53_CREATE_JSON=$(echo "${ROUTE53_CREATE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
    node_record=$(echo "${node_record}" |
      jq -r --arg ACTION "DELETE" '.Action = $ACTION')
    ROUTE53_DELETE_JSON=$(echo "${ROUTE53_DELETE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
  done
fi
echo "Creating json to create Node DNS records..."
echo "${ROUTE53_CREATE_JSON}" > "${SHARED_DIR}"/dns-nodes-create.json

echo "Creating json file to delete Node DNS records..."
echo "${ROUTE53_DELETE_JSON}" > "${SHARED_DIR}"/dns-nodes-delete.json

