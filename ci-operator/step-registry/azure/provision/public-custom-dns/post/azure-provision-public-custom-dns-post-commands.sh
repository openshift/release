#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

function add_lb_record() {
    local name="$1"
    local target="$2"
    local record_type="$3"
    local out="$4"
    if [ ! -e "$out" ]; then
        echo -n '[]' > "$out"
    fi
    cat <<< "$(jq --arg n "${name}" --arg t "${target}" --arg r "${record_type}" '. += [{"name": $n, "target": $t, "record_type": $r}]' "$out")" > "$out"
}

function get_lb_ip() {

    local lb_name=$1 port=$2 out=$3

    frontendipconfig_id=$(az network lb show -n ${lb_name} -g ${RESOURCE_GROUP} -ojson | jq -r ".loadBalancingRules[] | select(.frontendPort == ${port}) | .frontendIPConfiguration.id") || true
    if [[ -z "${frontendipconfig_id}" ]]; then
        echo "Warining: No LB rules with port ${port}!"
        return 0
    else
        frontendipconfig_name=${frontendipconfig_id##*/}

        frontendpublicip_id=$(az network lb frontend-ip show -n ${frontendipconfig_name} --lb-name ${lb_name} -g ${RESOURCE_GROUP} --query "publicIPAddress.id" -otsv)
        lb_ip=$(az network public-ip show --ids ${frontendpublicip_id} --query 'ipAddress' -otsv)
        echo "LB rule's(port: ${port}) frontend public IP in public LB: ${lb_ip}"
        echo "${lb_ip}" > ${out}
    fi
}

dns_reserve_and_defer_cleanup() {
  record=$1
  hostname=$2
  recordtype=$3

  json_create="{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"$hostname\",
      \"Type\": \"$recordtype\",
      \"TTL\": 60,
      \"ResourceRecords\": [{\"Value\": \"$record\"}]
    }
  }"
  jq --argjson jc "$json_create" '.Changes += [$jc]' "${SHARED_DIR}"/dns-create.json > "${SHARED_DIR}"/tmp-create.json && mv "${SHARED_DIR}"/tmp-create.json "${SHARED_DIR}"/dns-create.json

  json_delete="{
    \"Action\": \"DELETE\",
    \"ResourceRecordSet\": {
      \"Name\": \"$hostname\",
      \"Type\": \"$recordtype\",
      \"TTL\": 60,
      \"ResourceRecords\": [{\"Value\": \"$record\"}]
    }
  }"
  jq --argjson jd "$json_delete" '.Changes += [$jd]' "${SHARED_DIR}"/dns-delete.json > "${SHARED_DIR}"/tmp-delete.json && mv "${SHARED_DIR}"/tmp-delete.json "${SHARED_DIR}"/dns-delete.json
}

if [[ -f "${SHARED_DIR}"/public_custom_dns.json ]]; then
    echo "Warning: File public_custom_dns.json already exists in SHARED_DIR, skip the step!"
    exit 0
fi

if [[ -z "${BASE_DOMAIN}" ]]; then
    echo "Warning: env 'BASE_DOMAIN' is not set, could not be empty, please check!"
    exit 0
fi

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name!"
        exit 1
    fi
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")

    AZURESTACK_ENDPOINT=$(cat "${SHARED_DIR}"/AZURESTACK_ENDPOINT)
    SUFFIX_ENDPOINT=$(cat "${SHARED_DIR}"/SUFFIX_ENDPOINT)

    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
        export REQUESTS_CA_BUNDLE=/tmp/ca.pem
    fi
    az cloud register \
        -n ${cloud_name} \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name ${cloud_name}
    az cloud update --profile 2019-03-01-hybrid
else
    az cloud set --name AzureCloud
fi

az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
CLUSTER_NAME=$(yq-go r "${INSTALL_CONFIG}" 'metadata.name')
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

# api server
echo "Get lb ip for api server rule"
get_lb_ip "${INFRA_ID}" "6443" "${ARTIFACT_DIR}/apiserver_lb_ip"
if [[ -f "${ARTIFACT_DIR}/apiserver_lb_ip" ]]; then
    api_lb_ip="$(< "${ARTIFACT_DIR}/apiserver_lb_ip")"
    add_lb_record "api.${CLUSTER_NAME}.${BASE_DOMAIN}." "${api_lb_ip}" "A" "${SHARED_DIR}/public_custom_dns.json"
else
    echo "Unable to get apiserver rule's frontend IP from public/internal LB"
    exit 1
fi

# ingress
#echo "Get lb ip for ingress rule"
#get_lb_ip "${INFRA_ID}" "443" "${ARTIFACT_DIR}/ingress_lb_ip"
#if [[ -f "${ARTIFACT_DIR}/ingress_lb_ip" ]]; then
#    ingress_lb_ip="$(< "${ARTIFACT_DIR}/ingress_lb_ip")"
#    add_lb_record "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." "${ingress_lb_ip}" "A" "${SHARED_DIR}/public_custom_dns.json"
#else
#    echo "Warning: Unable to get ingress rule's frontend IP from public/internal LB"
#fi
echo "public_custom_dns.json:"
cat "${SHARED_DIR}"/public_custom_dns.json

# Create api/*.apps dns on AWS route53
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/route53.only.awscred"
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

echo "Creating api/*.apps dns on route53"
hosted_zone_id="$(aws route53 list-hosted-zones-by-name --dns-name "${BASE_DOMAIN}." --query "HostedZones[0].Id" --output text)"
if [[ -z "$hosted_zone_id" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: Could not find the public hosted zone ID for '${BASE_DOMAIN}.'"
  exit 1
fi
echo "${hosted_zone_id}" > "${SHARED_DIR}/hosted-zone.txt"

echo "$(date -u --rfc-3339=seconds) - INFO: Creating batch file to create DNS records"
cat > "${SHARED_DIR}"/dns-create.json <<EOF
{
"Comment": "Create public OpenShift DNS records for custom dns IPI CI install",
"Changes": []
}
EOF

echo "$(date -u --rfc-3339=seconds) - INFO: Creating batch file to destroy DNS records"
cat > "${SHARED_DIR}"/dns-delete.json <<EOF
{
"Comment": "Delete public OpenShift DNS records for custom dns IPI CI install",
"Changes": []
}
EOF

count=$(jq '.|length' ${SHARED_DIR}/public_custom_dns.json)
ret=0
for i in $(seq 0 $((count-1)));
do
    name=$(jq --argjson i $i -r '.[$i].name' ${SHARED_DIR}/public_custom_dns.json)
    target=$(jq --argjson i $i -r '.[$i].target' ${SHARED_DIR}/public_custom_dns.json)
    record_type=$(jq --argjson i $i -r '.[$i].record_type' ${SHARED_DIR}/public_custom_dns.json)

    if [[ -n "${target}" ]]; then
        echo "$(date -u --rfc-3339=seconds) - INFO: Adding '${name} ${target}' to batch files"
        dns_reserve_and_defer_cleanup "${target}" "${name}" "${record_type}"
    else
        echo "$(date -u --rfc-3339=seconds) - ERROR: Empty VIP for '${name}', skipped."
        ret=1
    fi
done

echo "dns-create.json:"
cat "${SHARED_DIR}/dns-create.json"

id=$(aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/dns-create.json --query '"ChangeInfo"."Id"' --output text)
echo "$(date -u --rfc-3339=seconds) - INFO: Waiting for DNS records to sync..."
aws route53 wait resource-record-sets-changed --id "$id"
echo "$(date -u --rfc-3339=seconds) - INFO: DNS records created."

echo "Waiting for ${AWS_NEW_PUBLIC_DNS_RECORD_WAITING_TIME}s to ensure DNS records can be resolved ..."
sleep $AWS_NEW_PUBLIC_DNS_RECORD_WAITING_TIME

exit "${ret}"
