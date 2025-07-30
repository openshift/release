#!/usr/bin/env bash

set -euo pipefail

function check_cm_operator() {
    echo "Checking the persence of the cert-manager Operator as prerequisite..."
    if ! oc wait deployment/cert-manager-operator-controller-manager -n cert-manager-operator --for=condition=Available --timeout=0; then
        echo "The cert-manager Operator is not installed or unavailable. Skipping rest of steps..."
        exit 0
    fi
}

function create_azure_dns_clusterissuer() {
    # Create secret containing Azure client secret
    (
        set +x
        oc create secret generic "$CLIENT_SECRET_NAME" -n "$OPERAND_NAMESPACE" --from-literal="$CLIENT_SECRET_KEY"="$AZURE_AUTH_CLIENT_SECRET"
    )

    # Create ClusterIssuer with Azure DNS resolver
    oc apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $CLUSTERISSUER_NAME
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: acme-dns01-account-key
    solvers:
    # For Ingress
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
OPERAND_NAMESPACE="cert-manager"

# Check if CM is installed
check_cm_operator

# Creat ClusterIssuer
case "${CLUSTER_TYPE}" in
*azure*)
    create_azure_dns_clusterissuer
    ;;
*)
    echo "Cluster type '${CLUSTER_TYPE}' unsupported, exiting..." >&2
    exit 1
    ;;
esac

# Wait for the ClusterIssuer to be ready
oc wait clusterissuer "$CLUSTERISSUER_NAME" --for=condition=Ready=True --timeout=180s
