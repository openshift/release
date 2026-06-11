#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# In dev mode, Vault is already initialized and unsealed with root token "root"
ROOT_TOKEN="root"

# Configure a Vault instance for KMS encryption.
# Args: $1 = namespace, $2 = KMS key name, $3 = pod name
configure_vault() {
  local ns="$1"
  local key_name="$2"
  local pod_name="$3"

  echo ""
  echo "========================================="
  echo "Vault Configuration for KMS"
  echo "========================================="
  echo "Namespace: ${ns}"
  echo "Vault Enterprise NS: ${VAULT_ENTERPRISE_NS}"
  echo "KMS Key Name: ${key_name}"
  echo ""

  echo "Configuring Vault for KMS..."
  echo ""

  # Create the Vault Enterprise namespace used by the KMS plugin
  echo "Creating Vault Enterprise namespace '${VAULT_ENTERPRISE_NS}'..."
  oc exec "${pod_name}" -n "${ns}" -- \
    env VAULT_TOKEN="${ROOT_TOKEN}" vault namespace create "${VAULT_ENTERPRISE_NS}"

  # Enable transit secret engine
  echo "Enabling transit secret engine..."
  oc exec "${pod_name}" -n "${ns}" -- \
    env VAULT_TOKEN="${ROOT_TOKEN}" vault secrets enable -namespace="${VAULT_ENTERPRISE_NS}" -path=transit transit

  # Create encryption key
  echo "Creating transit encryption key..."
  oc exec "${pod_name}" -n "${ns}" -- \
    env VAULT_TOKEN="${ROOT_TOKEN}" vault write -namespace="${VAULT_ENTERPRISE_NS}" -f "transit/keys/${key_name}"

  # Enable AppRole auth
  echo "Enabling AppRole authentication..."
  oc exec "${pod_name}" -n "${ns}" -- \
    env VAULT_TOKEN="${ROOT_TOKEN}" vault auth enable -namespace="${VAULT_ENTERPRISE_NS}" approle

  # Create KMS policy
  echo "Creating KMS policy..."
  oc exec "${pod_name}" -n "${ns}" -- \
    sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault policy write -namespace=${VAULT_ENTERPRISE_NS} kms-policy - <<POLICY
path \"transit/encrypt/${key_name}\" {
  capabilities = [\"update\"]
}
path \"transit/decrypt/${key_name}\" {
  capabilities = [\"update\"]
}
path \"transit/keys/${key_name}\" {
  capabilities = [\"read\"]
}
path \"sys/license/status\" {
  capabilities = [\"read\"]
}
POLICY"

  # Create AppRole role
  echo "Creating AppRole role..."
  oc exec "${pod_name}" -n "${ns}" -- \
    env VAULT_TOKEN="${ROOT_TOKEN}" vault write -namespace="${VAULT_ENTERPRISE_NS}" auth/approle/role/kms-plugin \
      token_policies=kms-policy \
      token_ttl=1h \
      token_max_ttl=4h

  # Get AppRole credentials
  echo "Retrieving AppRole credentials..."
  ROLE_ID=$(oc exec "${pod_name}" -n "${ns}" -- \
    env VAULT_TOKEN="${ROOT_TOKEN}" vault read -namespace="${VAULT_ENTERPRISE_NS}" -field=role_id auth/approle/role/kms-plugin/role-id)
  SECRET_ID=$(oc exec "${pod_name}" -n "${ns}" -- \
    env VAULT_TOKEN="${ROOT_TOKEN}" vault write -namespace="${VAULT_ENTERPRISE_NS}" -field=secret_id -f auth/approle/role/kms-plugin/secret-id)

  # Create vault-credentials secret
  echo "Creating vault-credentials secret..."
  oc create secret generic vault-credentials \
    --from-literal=role-id="${ROLE_ID}" \
    --from-literal=secret-id="${SECRET_ID}" \
    --from-literal=root-token="${ROOT_TOKEN}" \
    -n "${ns}"

  echo "Vault credentials saved to vault-credentials secret"

  echo ""
  echo "========================================="
  echo "Vault Configuration Complete"
  echo "========================================="
  echo ""
  echo "Summary:"
  echo "  - Vault Service: vault.${ns}.svc:8200"
  echo "  - Credentials Secret: vault-credentials (namespace: ${ns})"
  echo "  - Vault Enterprise Namespace: ${VAULT_ENTERPRISE_NS}"
  echo "  - Transit Key: ${key_name}"
  echo "  - ROLE_ID: ${ROLE_ID}"
  echo ""
}

configure_vault "${VAULT_NAMESPACE}" "${VAULT_KMS_KEY_NAME}" "vault-0"
configure_vault "${VAULT_SECONDARY_NAMESPACE}" "${VAULT_SECONDARY_KMS_KEY_NAME}" "vault-2-0"
