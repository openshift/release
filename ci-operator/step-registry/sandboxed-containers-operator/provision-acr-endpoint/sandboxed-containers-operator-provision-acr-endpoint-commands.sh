#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if test -s "${SHARED_DIR}/proxy-conf.sh"; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

ACR_RG="${ACR_RESOURCE_GROUP:-osc-ci-mirror-rg}"
ACR_NAME="${ACR_NAME:-osccimirror}"
ACR_LOCATION="${ACR_LOCATION:-eastus}"

if az acr show --name "${ACR_NAME}" --resource-group "${ACR_RG}" &>/dev/null; then
    echo "ACR ${ACR_NAME} already exists"
    az acr update --name "${ACR_NAME}" --resource-group "${ACR_RG}" --admin-enabled true --sku Premium --anonymous-pull-enabled true --output none
else
    echo "Creating resource group ${ACR_RG}..."
    az group create --name "${ACR_RG}" --location "${ACR_LOCATION}" --output none

    echo "Creating ACR ${ACR_NAME}..."
    az acr create \
        --resource-group "${ACR_RG}" \
        --name "${ACR_NAME}" \
        --sku Premium \
        --admin-enabled true \
        --output none

    az acr update --name "${ACR_NAME}" --resource-group "${ACR_RG}" --anonymous-pull-enabled true --output none
fi

ACR_LOGIN_SERVER=$(az acr show --name "${ACR_NAME}" --resource-group "${ACR_RG}" --query loginServer -o tsv)
echo "ACR_LOGIN_SERVER: ${ACR_LOGIN_SERVER}"

ACR_USERNAME=$(az acr credential show --name "${ACR_NAME}" --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name "${ACR_NAME}" --query "passwords[0].value" -o tsv)

# Build pull secret with ACR + build farm auth
acr_auth=$(echo -n "${ACR_USERNAME}:${ACR_PASSWORD}" | base64 -w 0)
pull_secret="${SHARED_DIR}/new_pull_secret"
jq --argjson a "{\"${ACR_LOGIN_SERVER}\": {\"auth\": \"${acr_auth}\"}}" \
    '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${pull_secret}"

# oc registry login needs direct access to build farm (no proxy)
saved_http_proxy="${http_proxy:-}" saved_https_proxy="${https_proxy:-}"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
unset KUBECONFIG
oc registry login --to "${pull_secret}"

# Private endpoint in cluster VNet (az commands need proxy)
export http_proxy="${saved_http_proxy}" https_proxy="${saved_https_proxy}"
export HTTP_PROXY="${saved_http_proxy}" HTTPS_PROXY="${saved_https_proxy}"
CLUSTER_RG=$(cat "${SHARED_DIR}/resourcegroup")
VNET_NAME=$(cat "${SHARED_DIR}/vnet_name" 2>/dev/null || \
    az network vnet list --resource-group "${CLUSTER_RG}" --query "[0].name" -o tsv)
SUBNET_NAME="${ACR_ENDPOINT_SUBNET:-}"
if [[ -z "${SUBNET_NAME}" ]]; then
    SUBNET_NAME=$(az network vnet subnet list --resource-group "${CLUSTER_RG}" --vnet-name "${VNET_NAME}" --query "[?contains(name,'worker')].name | [0]" -o tsv)
    if [[ -z "${SUBNET_NAME}" ]]; then
        SUBNET_NAME=$(az network vnet subnet list --resource-group "${CLUSTER_RG}" --vnet-name "${VNET_NAME}" --query "[-1].name" -o tsv)
    fi
fi
echo "Using subnet: ${SUBNET_NAME}"

ACR_ID=$(az acr show --name "${ACR_NAME}" --resource-group "${ACR_RG}" --query id -o tsv)
ENDPOINT_NAME="osc-acr-pe-${CLUSTER_RG##*-}"

az network vnet subnet update \
    --resource-group "${CLUSTER_RG}" \
    --vnet-name "${VNET_NAME}" \
    --name "${SUBNET_NAME}" \
    --disable-private-endpoint-network-policies true \
    --output none 2>/dev/null || true

az network private-endpoint create \
    --name "${ENDPOINT_NAME}" \
    --resource-group "${CLUSTER_RG}" \
    --vnet-name "${VNET_NAME}" \
    --subnet "${SUBNET_NAME}" \
    --private-connection-resource-id "${ACR_ID}" \
    --group-id registry \
    --connection-name "osc-acr-connection" \
    --output none

for i in $(seq 1 12); do
    ACR_PRIVATE_IP=$(az network private-endpoint show \
        --name "${ENDPOINT_NAME}" \
        --resource-group "${CLUSTER_RG}" \
        --query "customDnsConfigs[0].ipAddresses[0]" -o tsv 2>/dev/null || echo "")

    if [[ -n "${ACR_PRIVATE_IP}" && "${ACR_PRIVATE_IP}" != "None" ]]; then
        echo "ACR private IP: ${ACR_PRIVATE_IP}"
        break
    fi
    echo "Waiting for private endpoint IP... (${i}/12)"
    sleep 10
done

if [[ -z "${ACR_PRIVATE_IP}" || "${ACR_PRIVATE_IP}" == "None" ]]; then
    echo "ERROR: Could not get private endpoint IP"
    echo "PE details:"
    az network private-endpoint show --name "${ENDPOINT_NAME}" --resource-group "${CLUSTER_RG}" -o json 2>&1 | head -50
    exit 1
fi

DNS_ZONE="privatelink.azurecr.io"
az network private-dns zone create \
    --resource-group "${CLUSTER_RG}" --name "${DNS_ZONE}" \
    --output none 2>/dev/null || true

az network private-dns link vnet create \
    --resource-group "${CLUSTER_RG}" --zone-name "${DNS_ZONE}" \
    --name "osc-acr-dns-link" --virtual-network "${VNET_NAME}" \
    --registration-enabled false \
    --output none 2>/dev/null || true

echo "Creating DNS records from PE customDnsConfigs..."
az network private-endpoint show \
    --name "${ENDPOINT_NAME}" \
    --resource-group "${CLUSTER_RG}" \
    --query "customDnsConfigs[].[fqdn,ipAddresses[0]]" -o tsv | while read -r fqdn ip; do
    record_name="${fqdn%.azurecr.io}"
    echo "  ${record_name} -> ${ip}"
    az network private-dns record-set a add-record \
        --resource-group "${CLUSTER_RG}" --zone-name "${DNS_ZONE}" \
        --record-set-name "${record_name}" --ipv4-address "${ip}" \
        --output none 2>/dev/null || true
done

echo "${ACR_LOGIN_SERVER}" > "${SHARED_DIR}/mirror_registry_url"
echo -n "${ACR_USERNAME}:${ACR_PASSWORD}" > "${SHARED_DIR}/acr_registry_creds"

# Mirror OCP release if not already present
# oc commands need direct access (no proxy) to build farm and ACR
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
RELEASE_IMAGE="${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
readable_version=$(oc adm release info -a "${pull_secret}" "${RELEASE_IMAGE}" -o jsonpath='{.metadata.version}')
target_release="${ACR_LOGIN_SERVER}/openshift/release:${readable_version}"
target_repo="${ACR_LOGIN_SERVER}/openshift/release"

if oc image info -a "${pull_secret}" "${target_release}" &>/dev/null; then
    echo "OCP release ${readable_version} already in ACR, skipping mirror"
else
    echo "Mirroring OCP release ${readable_version} to ACR..."
    oc adm release mirror \
        -a "${pull_secret}" \
        --from="${RELEASE_IMAGE}" \
        --to="${target_repo}" \
        --to-release-image="${target_release}"
fi

echo "Pull secret with CI + ACR auth saved to ${pull_secret}"

ci_registry_source="${RELEASE_IMAGE%@*}"
cat > "${SHARED_DIR}/install-config-mirror.yaml.patch" <<EOF
imageDigestSources:
- mirrors:
  - ${target_repo}
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
- mirrors:
  - ${target_repo}
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - ${target_repo}
  source: ${ci_registry_source}
EOF

echo "Done. ACR: ${ACR_LOGIN_SERVER}, release: ${readable_version}"
