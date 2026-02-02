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

ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
if (( ${ocp_minor_version} < 17 )); then
    echo "This step only supports to covert cluster into private one in day2 on 4.17+ currently!"
    exit 1
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

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
BASE_DOMAIN=$(yq-go r "${INSTALL_CONFIG}" 'baseDomain')
BASE_DOMAIN_RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.baseDomainResourceGroupName')
CLUSTER_NAME=$(yq-go r "${INSTALL_CONFIG}" 'metadata.name')
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

# Setting the Ingress Controller to private
echo "Configuring DNS records to be published in the private zone"
run_command "oc patch dnses.config.openshift.io/cluster --type=merge --patch='{\"spec\": {\"publicZone\": null}}'"

echo "Setting the Ingress Controller to private"
# after this, following resources are updated automatically
# 1. rules with port 80/443 are removed from external lb
# 2. rules with port 80/443 are created in internal lb
# 3. Public IP associated with those rule in externa lb is deleted
# 4. *.app dns record is deleted from public dns zone
oc replace --force --wait --filename - <<EOF
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  namespace: openshift-ingress-operator
  name: default
spec:
  endpointPublishingStrategy:
    type: LoadBalancerService
    loadBalancer:
      scope: Internal
EOF

# Restricting the API server to private
frontend_ip=$(az network lb rule show -n api-v4 --lb-name ${INFRA_ID} -g ${RESOURCE_GROUP} --query 'frontendIPConfiguration.id' -otsv | awk -F'/' '{print $NF}')
api_public_ip_id=$(az network lb frontend-ip show --name ${frontend_ip} --lb-name ${INFRA_ID} -g ${RESOURCE_GROUP} --query 'publicIPAddress.id' -otsv)

echo "Restricting the API server to private - delete inbound rule api-v4 from external lb"
run_command "az network lb rule delete -n api-v4 --lb-name ${INFRA_ID} -g ${RESOURCE_GROUP}"

echo "Restricting the API server to private - delete associated frontend public ip from external lb"
# Try to clean up the stale reference by updating LB
echo "Attempting to clean stale references..."
run_command "az network lb update --name  ${INFRA_ID} -g ${RESOURCE_GROUP}"
run_command "az network lb frontend-ip delete --name ${frontend_ip} --lb-name ${INFRA_ID} -g ${RESOURCE_GROUP}"

echo "Restricting the API server to private - delete frontend public IP associated with rule api-v4"
run_command "az network public-ip delete --ids ${api_public_ip_id}"

echo "Restricting the API server to private - delete api dns record from public dns zone"
run_command "az network dns record-set cname delete --name api.${CLUSTER_NAME} --zone-name ${BASE_DOMAIN} -g ${BASE_DOMAIN_RESOURCE_GROUP} --yes"

#api-v4 inbound rule is deleted from external lb, need to export proxy to access the cluster
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
else
  echo "No proxy-conf found, exit now"
  exit 1
fi

# Configure a private storage endpoint on Azure
echo "Configure a private storage endpoint on Azure by enabling the image registry operator to discover vnet and subnet names"
vnet_resource_group=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.networkResourceGroupName')
if [[ -n "${vnet_resource_group}" ]]; then
    run_command "oc patch config.image/cluster -p '{\"spec\":{\"storage\":{\"azure\":{\"networkAccess\":{\"type\": \"Internal\",\"internal\":{\"networkResourceGroupName\":\"${vnet_resource_group}\"}}}}}}' --type=merge"
else
    run_command "oc patch config.image/cluster -p '{\"spec\":{\"storage\":{\"azure\":{\"networkAccess\":{\"type\": \"Internal\"}}}}}' --type=merge"
fi

# FIXME: add this when https://issues.redhat.com/browse/OCPBUGS-30196 is fixed
# Optional: Disabling redirect when using a private storage endpoint on Azure

echo "Waiting for image registry become Available..."
sleep 600s
#run_command "oc wait --for condition=Progressing=True co/image-registry --timeout=600s" || ret=1
run_command "oc wait --for=condition=Available --for condition=Progressing=False --for condition=Degraded=False co/image-registry --timeout=1200s"
