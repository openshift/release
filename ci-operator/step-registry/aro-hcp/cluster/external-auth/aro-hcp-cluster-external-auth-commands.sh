#!/usr/bin/env bash

# Never emit commands or credential-bearing arguments through shell tracing.
set +x
set -o errexit
set -o nounset
set -o pipefail

trap 'children=$(jobs -p); if [[ -n "${children}" ]]; then kill ${children} 2>/dev/null || true; wait ${children} 2>/dev/null || true; fi' TERM INT

STEP_NUMBER=0
log_step() {
  STEP_NUMBER=$((STEP_NUMBER + 1))
  echo "[external-auth step ${STEP_NUMBER}] $*"
}

state_value() {
  local key="$1"
  local state_file="${SHARED_DIR}/aro-hcp.env"
  if [[ -s "${state_file}" ]]; then
    awk -F= -v key="${key}" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "${state_file}"
  fi
}

log_step "Resolving the ARO HCP cluster identity."
CLUSTER_NAME="${ARO_HCP_CLUSTER_NAME:-}"
if [[ -z "${CLUSTER_NAME}" && -s "${SHARED_DIR}/cluster-name" ]]; then
  CLUSTER_NAME=$(tr -d '\r\n' < "${SHARED_DIR}/cluster-name")
fi
if [[ -z "${CLUSTER_NAME}" ]]; then
  CLUSTER_NAME=$(state_value CLUSTER_NAME)
fi
: "${CLUSTER_NAME:?ARO HCP cluster name was not supplied or published in SHARED_DIR}"

CUSTOMER_RG_NAME="${ARO_HCP_CUSTOMER_RG_NAME:-}"
if [[ -z "${CUSTOMER_RG_NAME}" ]]; then
  CUSTOMER_RG_NAME=$(state_value CUSTOMER_RG_NAME)
fi
CUSTOMER_RG_NAME="${CUSTOMER_RG_NAME:-${CLUSTER_NAME}-rg}"

SUBSCRIPTION_ID=$(state_value AZURE_SUBSCRIPTION_ID)
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id --output tsv 2>/dev/null || true)}"
: "${SUBSCRIPTION_ID:?Azure subscription could not be determined}"

EXTERNAL_AUTH_NAME="${EXTERNAL_AUTH_NAME:-${CLUSTER_NAME}}"
if (( ${#EXTERNAL_AUTH_NAME} > 15 )); then
  echo "${EXTERNAL_AUTH_NAME} is too long for the ARO HCP ExternalAuth resource name; use 15 characters or fewer." >&2
  exit 1
fi

GUEST_KUBECONFIG="${KUBECONFIG:-${SHARED_DIR}/kubeconfig}"
SP_FILE="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ ! -s "${SP_FILE}" ]]; then
  echo "${SP_FILE} is missing from the selected Azure cluster profile." >&2
  exit 1
fi

log_step "Authenticating to Azure."
export AZURE_CONFIG_DIR="${SHARED_DIR}/azure-config"
mkdir -p "${AZURE_CONFIG_DIR}"
umask 077
AZURE_CLIENT_ID=$(jq -er '.clientId' "${SP_FILE}")
AZURE_CLIENT_SECRET=$(jq -er '.clientSecret' "${SP_FILE}")
AZURE_TENANT_ID=$(jq -er '.tenantId' "${SP_FILE}")
EXTERNAL_AUTH_ISSUER_URL="${EXTERNAL_AUTH_ISSUER_URL:-https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0}"

set +x
az login \
  --service-principal \
  --username "${AZURE_CLIENT_ID}" \
  --password "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --only-show-errors \
  --output none
unset AZURE_CLIENT_SECRET AZURE_TENANT_ID
az account set --subscription "${SUBSCRIPTION_ID}"

if ! command -v oc >/dev/null 2>&1; then
  echo "oc is required to configure the guest external-auth Secret and binding." >&2
  exit 1
fi

duration_to_seconds() {
  local value="$1"
  if [[ "${value}" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "${value}" =~ ^([0-9]+)m$ ]]; then
    echo $((BASH_REMATCH[1] * 60))
  elif [[ "${value}" =~ ^([0-9]+)h$ ]]; then
    echo $((BASH_REMATCH[1] * 3600))
  elif [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "${value}"
  else
    echo "Unsupported duration: ${value}" >&2
    return 1
  fi
}

log_step "Waiting for the ARO console URL needed by external auth."
external_auth_deadline=$((SECONDS + $(duration_to_seconds "${EXTERNAL_AUTH_TIMEOUT}")))
console_url=""
while (( SECONDS < external_auth_deadline )); do
  console_url=$(az aro hcp cluster show \
    --name "${CLUSTER_NAME}" \
    --resource-group "${CUSTOMER_RG_NAME}" \
    --query properties.console.url \
    --output tsv 2>/dev/null || true)
  if [[ "${console_url}" == http* ]]; then
    break
  fi
  echo "ARO console URL is not available yet; retrying in 30s."
  sleep 30
done
if [[ "${console_url}" != http* ]]; then
  echo "ARO console URL was not available before the external-auth timeout." >&2
  exit 1
fi

external_auth_bicep="${SHARED_DIR}/aro-hcp-external-auth.bicep"
cat >"${external_auth_bicep}" <<'BICEP'
@description('The name of the external auth provider configuration')
param externalAuthName string

@description('The Entra issuer URL')
param issuerURL string

@description('The Entra application client ID')
param clientID string

@description('The name of the hosted control-plane cluster')
param clusterName string

resource hcp 'Microsoft.RedHatOpenShift/hcpOpenShiftClusters@2025-12-23-preview' existing = {
  name: clusterName
}

resource externalAuth 'Microsoft.RedHatOpenShift/hcpOpenShiftClusters/externalAuths@2025-12-23-preview' = {
  parent: hcp
  name: externalAuthName
  properties: {
    claim: {
      mappings: {
        username: {
          claim: 'email'
        }
        groups: {
          claim: 'groups'
        }
      }
    }
    clients: [
      {
        clientId: clientID
        component: {
          name: 'console'
          authClientNamespace: 'openshift-console'
        }
        type: 'Confidential'
      }
      {
        clientId: clientID
        component: {
          name: 'cli'
          authClientNamespace: 'openshift-console'
        }
        type: 'Public'
      }
    ]
    issuer: {
      url: issuerURL
      audiences: [
        clientID
      ]
    }
  }
}
BICEP

log_step "Creating the Entra application for external auth."
external_auth_app_id=""
external_auth_app_secret=""
if ! external_auth_app_id=$(az ad app create \
  --display-name "${EXTERNAL_AUTH_NAME}" \
  --web-redirect-uris "${console_url%/}/auth/callback" "http://localhost:8000" \
  --query appId \
  --output tsv \
  --only-show-errors); then
  echo "Failed to create the Entra application for ${CLUSTER_NAME}." >&2
  exit 1
fi

log_step "Creating the Entra application secret."
for attempt in 1 2 3 4 5; do
  if external_auth_app_secret=$(az ad app credential reset \
    --id "${external_auth_app_id}" \
    --query password \
    --output tsv \
    --only-show-errors 2>/dev/null) && [[ -n "${external_auth_app_secret}" ]]; then
    break
  fi
  if (( attempt == 5 )); then
    echo "Failed to create the Entra application secret after ${attempt} attempts." >&2
    exit 1
  fi
  sleep 10
done

# Keep the deployment name unique per cluster. The ExternalAuth child name is
# intentionally separate and remains bounded by the RP's 15-character limit.
deployment_name="aro-hcp-auth-${CLUSTER_NAME}"
log_step "Creating the ARO HCP ExternalAuth resource with Bicep."
az deployment group create \
  --name "${deployment_name}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --template-file "${external_auth_bicep}" \
  --parameters \
    externalAuthName="${EXTERNAL_AUTH_NAME}" \
    issuerURL="${EXTERNAL_AUTH_ISSUER_URL}" \
    clientID="${external_auth_app_id}" \
    clusterName="${CLUSTER_NAME}" \
  --only-show-errors \
  --output none

log_step "Allowing the ExternalAuth configuration to propagate."
sleep 60

if [[ ! -s "${GUEST_KUBECONFIG}" ]]; then
  log_step "Requesting the administrator kubeconfig for guest configuration."
  az aro hcp cluster request-credential \
    --admin \
    --name "${CLUSTER_NAME}" \
    --resource-group "${CUSTOMER_RG_NAME}" \
    --subscription "${SUBSCRIPTION_ID}" \
    --file "${GUEST_KUBECONFIG}" \
    --overwrite-existing \
    --only-show-errors
fi
chmod 600 "${GUEST_KUBECONFIG}"

log_step "Creating the guest external-auth client-secret."
secret_name="${EXTERNAL_AUTH_NAME}-console-openshift-console"
jq -n \
  --arg name "${secret_name}" \
  --arg client_secret "${external_auth_app_secret}" \
  '{apiVersion: "v1", kind: "Secret", metadata: {name: $name, namespace: "openshift-config"}, type: "Opaque", stringData: {clientSecret: $client_secret}}' \
  | KUBECONFIG="${GUEST_KUBECONFIG}" oc apply --filename - --request-timeout=60s

log_step "Resolving the Entra admin group and creating the guest binding."
group_id=$(az ad group show \
  --group "${AZURE_AD_GROUP_NAME}" \
  --query id \
  --output tsv \
  --only-show-errors)
if [[ -z "${group_id}" ]]; then
  echo "The Entra group ${AZURE_AD_GROUP_NAME} was not found." >&2
  exit 1
fi
jq -n \
  --arg group_id "${group_id}" \
  '{apiVersion: "rbac.authorization.k8s.io/v1", kind: "ClusterRoleBinding", metadata: {name: "aro-admins"}, roleRef: {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: "cluster-admin"}, subjects: [{apiGroup: "rbac.authorization.k8s.io", kind: "Group", name: $group_id}]}' \
  | KUBECONFIG="${GUEST_KUBECONFIG}" oc apply --filename - --request-timeout=60s

unset external_auth_app_secret AZURE_CLIENT_ID
log_step "ARO HCP external authentication is configured for ${CLUSTER_NAME}."
