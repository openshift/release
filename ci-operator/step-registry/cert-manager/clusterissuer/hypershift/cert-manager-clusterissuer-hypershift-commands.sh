#!/usr/bin/env bash

set -euo pipefail

function create_azure_dns_clusterissuer() {
    # Create secret containing Azure client secret
    (
        set +x
        oc create secret generic "$CLIENT_SECRET_NAME" -n "$OPERAND_NAMESPACE" --from-literal="$CLIENT_SECRET_KEY"="$AZURE_AUTH_CLIENT_SECRET"
    )

    # Create ClusterIssuer with Azure DNS resolver
    oc create -f - << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $CLUSTERISSUER_NAME
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: $PRIVATE_KEY_SECRET_NAME
    solvers:
    # For ingress
    - selector:
        dnsZones:
        - $HYPERSHIFT_BASE_DOMAIN
      dns01:
        azureDNS:
          clientID: $AZURE_AUTH_CLIENT_ID
          clientSecretSecretRef:
            name: $CLIENT_SECRET_NAME
            key: $CLIENT_SECRET_KEY
          subscriptionID: $AZURE_AUTH_SUBSCRIPTION_ID
          tenantID: $AZURE_AUTH_TENANT_ID
          resourceGroupName: os4-common
          hostedZoneName: $HYPERSHIFT_BASE_DOMAIN
          environment: AzurePublicCloud
    # For KAS & OAuth
    - selector:
        dnsZones:
        - $HYPERSHIFT_EXTERNAL_DNS_DOMAIN
      dns01:
        azureDNS:
          clientID: $AZURE_AUTH_CLIENT_ID
          clientSecretSecretRef:
            name: $CLIENT_SECRET_NAME
            key: $CLIENT_SECRET_KEY
          subscriptionID: $AZURE_AUTH_SUBSCRIPTION_ID
          tenantID: $AZURE_AUTH_TENANT_ID
          resourceGroupName: os4-common
          hostedZoneName: $HYPERSHIFT_EXTERNAL_DNS_DOMAIN
          environment: AzurePublicCloud
EOF
}

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Get Azure client info
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

set -x

# Timestamp
export PS4='[$(date "+%Y-%m-%d %H:%M:%S")] '

# Cluster configurations
HYPERSHIFT_BASE_DOMAIN="$(oc get dns cluster -o=jsonpath='{.spec.baseDomain}')"
HYPERSHIFT_BASE_DOMAIN="$(cut -d '.' -f 1 --complement <<< "$HYPERSHIFT_BASE_DOMAIN")"
KAS_ROUTE_HOSTNAME="$(KUBECONFIG="${SHARED_DIR}"/mgmt_kubeconfig oc get hc -A -o jsonpath='{.items[0].spec.services[?(@.service=="APIServer")].servicePublishingStrategy.route.hostname}')"
if [[ -z "$KAS_ROUTE_HOSTNAME" ]]; then
    echo "HC not using Route KAS, exiting" >&2
    exit 1
fi
HYPERSHIFT_EXTERNAL_DNS_DOMAIN="$(cut -d '.' -f 1 --complement <<< "$KAS_ROUTE_HOSTNAME")"

# CM configurations
CLIENT_SECRET_KEY="client-secret"
CLIENT_SECRET_NAME="azuredns-config"
CLUSTERISSUER_NAME="cluster-certs-clusterissuer" # referenced by the 'cert-manager-custom-apiserver-cert' and 'cert-manager-custom-ingress-cert' steps
OPERATOR_NAMESPACE="cert-manager-operator"
OPERAND_NAMESPACE="cert-manager"
PRIVATE_KEY_SECRET_NAME="acme-dns01-account-key"
SUB="openshift-cert-manager-operator"

# Check if CM is installed
INSTALLED_CSV="$(oc get subscription "$SUB" -n "$OPERATOR_NAMESPACE" -o=jsonpath='{.status.installedCSV}')"
if [[ -z "${INSTALLED_CSV}" ]]; then
    echo "CM not installed. Invoke cert-manager-install first." >&2
    exit 1
fi

# Creat clusterissuer
case "${CLUSTER_TYPE,,}" in
*azure*)
    create_azure_dns_clusterissuer
    ;;
*)
    echo "Cluster type ${CLUSTER_TYPE} unsupported, exiting" >&2
    exit 1
    ;;
esac

# Wait for the clusterissuer to be ready
oc wait ClusterIssuer "$CLUSTERISSUER_NAME" --for=condition=Ready=True --timeout=180s
