#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "Vault Configuration for KMS"
echo "========================================="
echo "Namespace: ${VAULT_NAMESPACE}"
echo ""

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# In dev mode, Vault is already initialized and unsealed with root token "root"
ROOT_TOKEN="root"

echo "Configuring Vault for KMS..."
echo ""

# Enable transit secret engine
echo "Enabling transit secret engine..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault secrets enable -path=transit transit

# Create encryption key
echo "Creating transit encryption key..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault write -f transit/keys/${VAULT_KMS_KEY_NAME}

# Enable AppRole auth
echo "Enabling AppRole authentication..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault auth enable approle

# Create KMS policy
echo "Creating KMS policy..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault policy write kms-policy - <<POLICY
path \"transit/encrypt/${VAULT_KMS_KEY_NAME}\" {
  capabilities = [\"update\"]
}
path \"transit/decrypt/${VAULT_KMS_KEY_NAME}\" {
  capabilities = [\"update\"]
}
path \"transit/keys/${VAULT_KMS_KEY_NAME}\" {
  capabilities = [\"read\"]
}
path \"sys/license/status\" {
  capabilities = [\"read\"]
}
POLICY"

# Create AppRole role
echo "Creating AppRole role..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault write auth/approle/role/kms-plugin \
    token_policies=kms-policy \
    token_ttl=1h \
    token_max_ttl=4h

# Get AppRole credentials
echo "Retrieving AppRole credentials..."
ROLE_ID=$(oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault read -field=role_id auth/approle/role/kms-plugin/role-id)
SECRET_ID=$(oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault write -field=secret_id -f auth/approle/role/kms-plugin/secret-id)

# Create vault-credentials secret
echo "Creating vault-credentials secret..."
oc create secret generic vault-credentials \
  --from-literal=role-id="${ROLE_ID}" \
  --from-literal=secret-id="${SECRET_ID}" \
  --from-literal=root-token="${ROOT_TOKEN}" \
  -n "${VAULT_NAMESPACE}"

echo "Vault credentials saved to vault-credentials secret"

echo ""
echo "========================================="
echo "Vault Configuration Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Vault Service: vault.${VAULT_NAMESPACE}.svc:8200"
echo "  - Credentials Secret: vault-credentials (namespace: ${VAULT_NAMESPACE})"
echo "  - Transit Key: ${VAULT_KMS_KEY_NAME}"
echo "  - ROLE_ID: ${ROLE_ID}"
echo ""
