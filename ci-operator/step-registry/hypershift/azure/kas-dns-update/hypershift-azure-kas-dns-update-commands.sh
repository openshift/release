#!/bin/bash
set -euo pipefail
set -x

if [[ -z "${HYPERSHIFT_DYNAMIC_DNS:-}" ]]; then
  echo "HYPERSHIFT_DYNAMIC_DNS not set, skipping KAS DNS update"
  exit 0
fi

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
  AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Get cluster name
CLUSTER_NAME=$(oc get hostedclusters -n clusters -o jsonpath='{.items[0].metadata.name}')
echo "Cluster name: ${CLUSTER_NAME}"

# Get KAS DNS name from HostedCluster spec
KAS_DNS_NAME=$(oc get hc/${CLUSTER_NAME} -n clusters -o jsonpath='{.spec.kubeAPIServerDNSName}')
if [[ -z "${KAS_DNS_NAME}" ]]; then
    echo "INFO: KubeAPI Server DNS name not configured for '${CLUSTER_NAME}'"
    exit 0
fi
echo "KAS DNS Name: ${KAS_DNS_NAME}"

# Wait for KAS Route to be ready
echo "Waiting for KAS Route to be ready..."
KAS_ROUTE=""
for i in {1..30}; do
    KAS_ROUTE=$(oc get route -n clusters-${CLUSTER_NAME} kube-apiserver -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || echo "")
    if [[ -n "${KAS_ROUTE}" ]]; then
        break
    fi
    echo "Waiting for KAS Route... (attempt $i/30)"
    sleep 10
done

if [[ -z "${KAS_ROUTE}" ]]; then
    echo "ERROR: KAS Route not found after waiting"
    exit 1
fi

echo "KAS Route: ${KAS_ROUTE}"
echo "Updating KAS DNS CNAME: ${KAS_DNS_NAME} -> ${KAS_ROUTE}"

# Azure login
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

# Extract DNS components
RECORD_NAME="${KAS_DNS_NAME%%.*}"
DNS_ZONE="${KAS_DNS_NAME#*.}"

echo "Updating DNS record:"
echo "  Record Name: ${RECORD_NAME}"
echo "  DNS Zone: ${DNS_ZONE}"
echo "  Target: ${KAS_ROUTE}"

# Update CNAME record
az network dns record-set cname set-record \
  --resource-group "$DNS_ZONE_RG_NAME" \
  --zone-name "${DNS_ZONE}" \
  --record-set-name "${RECORD_NAME}" \
  --cname "${KAS_ROUTE}"

echo "✓ KAS DNS record updated successfully"

# Verify DNS record
az network dns record-set cname show \
  --resource-group "$DNS_ZONE_RG_NAME" \
  --zone-name "${DNS_ZONE}" \
  --name "${RECORD_NAME}" \
  --query "{Name:name, CNAME:cnameRecord.cname}" -o table

echo "Testing DNS resolution..."
sleep 10

# Try to resolve DNS (may take time to propagate)
for i in {1..30}; do
  if nslookup "${KAS_DNS_NAME}" > /dev/null 2>&1; then
    RESOLVED_IP=$(nslookup "${KAS_DNS_NAME}" | grep -A1 "Name:" | tail -1 | awk '{print $2}')
    echo "✓ DNS resolution successful: ${KAS_DNS_NAME} -> ${RESOLVED_IP}"
    exit 0
  fi
  echo "Waiting for DNS propagation... (attempt $i/30)"
  sleep 10
done

echo "WARNING: DNS not fully propagated yet, but CNAME record was updated"
echo "This is normal for DNS propagation delays. The record is configured correctly."
exit 0
