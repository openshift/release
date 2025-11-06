#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]] ; then
    AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

if [ ! -f ${SHARED_DIR}/keycloak-prefix ] ; then
    echo "The keycloak-prefix file must be provided by a previous step!"
    exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
KEYCLOAK_PREFIX="$(cat ${SHARED_DIR}/keycloak-prefix)"
KEYCLOAK_HOST="${KEYCLOAK_PREFIX}.${HYPERSHIFT_BASE_DOMAIN}"
DNS_ZONE_RG_NAME="os4-common"
INGRESS_EXTERNALIP="$(oc get svc -n ingress-nginx ingress-nginx-controller -ojsonpath='{.status.loadBalancer.ingress[].ip}')"
export KEYCLOAK_TLS_SECRET="${KEYCLOAK_HOST}-tls"

# Create dns record for keycloak host
az network dns record-set a add-record \
  --resource-group ${DNS_ZONE_RG_NAME} \
  --zone-name ${HYPERSHIFT_BASE_DOMAIN} --record-set-name  ${KEYCLOAK_PREFIX}\
  --ipv4-address ${INGRESS_EXTERNALIP}

timeout 10m bash -c '
  while ! oc get secret "${KEYCLOAK_TLS_SECRET}" -n keycloak &> /dev/null; do
    echo "Waiting for ${KEYCLOAK_TLS_SECRET} secret to be created..."
    sleep 15
  done
  echo "${KEYCLOAK_TLS_SECRET} secret is created!"
'
# Get keycloak certificate
mkdir -p /tmp/router-ca
oc extract secret/${KEYCLOAK_TLS_SECRET} -n keycloak --to /tmp/router-ca --confirm
cp /tmp/router-ca/tls.crt ${SHARED_DIR}/oidcProviders-ca.crt

# Check keycloak host connection
sleep 60
curl -sSI --cacert /tmp/router-ca/tls.crt https://${KEYCLOAK_HOST}/realms/master/.well-known/openid-configuration | grep -Eq 'HTTP/[^ ]+ 200'

if [ $? -ne 0 ]; then
  echo "ERROR: Failed to access Keycloak OpenID configuration at https://${KEYCLOAK_HOST}"
  echo "Possible reasons: TLS certificate invalid, Keycloak not running, or URL incorrect"
  exit 1
fi
echo "Success: Keycloak OpenID configuration is accessible"

# Save user info for later using
if [ ! -f "${SHARED_DIR}"/oidcProviders-secret-configmap.yaml ] ; then
    echo "The oidcProviders-secret-configmap.yaml file must be provided by a previous step!"
    exit 1
fi
echo "---" >> "${SHARED_DIR}"/oidcProviders-secret-configmap.yaml
oc create configmap keycloak-oidc-ca --from-file=ca-bundle.crt=/tmp/router-ca/tls.crt --dry-run=client -o yaml >> "${SHARED_DIR}"/oidcProviders-secret-configmap.yaml

if [ -f "${SHARED_DIR}/runtime_env" ] ; then
    source "${SHARED_DIR}/runtime_env"
fi

cat << EOF >> "${SHARED_DIR}/runtime_env"
export KEYCLOAK_CA_BUNDLE_FILE=$SHARED_DIR/oidcProviders-ca.crt
EOF
