#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Configure a Vault instance for KMS encryption.
# Args: $1 = namespace, $2 = KMS key name, $3 = pod name
configure_vault() {
  local namespace="$1"
  local key_name="$2"
  local pod_name="$3"
  local service_name="${pod_name%-0}"

  # Disable tracing due to password handling
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  local ROOT_TOKEN
  ROOT_TOKEN="$(oc get secret vault-root-token -n "${namespace}" -o jsonpath='{.data.token}' | base64 -d)"
  $WAS_TRACING && set -x

  vault_cli() {
    oc exec -c vault "${pod_name}" -n "${namespace}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="${ROOT_TOKEN}" \
      vault "$@"
  }

  vault_cli_ok_if_exists() {
    local out rc
    set +e
    out="$(vault_cli "$@" 2>&1)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      printf '%s\n' "${out}"
      return 0
    fi
    if printf '%s\n' "${out}" | grep -qiE 'already exists|already in use|path is already'; then
      echo "Already configured, continuing"
      return 0
    fi
    printf '%s\n' "${out}"
    return "${rc}"
  }

  unseal_vault_if_needed() {
    local status_rc=0
    set +e
    oc exec -c vault "${pod_name}" -n "${namespace}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault status >/dev/null 2>&1
    status_rc=$?
    set -e
    if [[ "${status_rc}" -eq 0 ]]; then
      return 0
    fi
    if [[ "${status_rc}" -ne 2 ]]; then
      echo "vault status failed with exit code ${status_rc}"
      return "${status_rc}"
    fi

    echo "Vault is sealed; unsealing with stored key..."
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x
    local unseal_key
    unseal_key="$(oc get secret vault-unseal-key -n "${namespace}" -o jsonpath='{.data.unseal-key}' | base64 -d)"
    oc exec -c vault "${pod_name}" -n "${namespace}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault operator unseal "${unseal_key}" >/dev/null
    unset unseal_key
    $WAS_TRACING && set -x
  }

  echo ""
  echo "========================================="
  echo "Vault Configuration for KMS"
  echo "========================================="
  echo "Namespace: ${namespace}"
  echo "Vault Enterprise NS: ${VAULT_ENTERPRISE_NS}"
  echo "KMS Key Name: ${key_name}"
  echo ""

  echo "Configuring Vault for KMS..."
  echo ""

  unseal_vault_if_needed

  echo "Creating Vault Enterprise namespace '${VAULT_ENTERPRISE_NS}'..."
  vault_cli_ok_if_exists namespace create "${VAULT_ENTERPRISE_NS}"

  echo "Enabling transit secret engine..."
  vault_cli_ok_if_exists secrets enable -namespace="${VAULT_ENTERPRISE_NS}" -path=transit transit

  echo "Creating transit encryption key..."
  vault_cli_ok_if_exists write -namespace="${VAULT_ENTERPRISE_NS}" -f "transit/keys/${key_name}"

  echo "Enabling AppRole authentication..."
  vault_cli_ok_if_exists auth enable -namespace="${VAULT_ENTERPRISE_NS}" approle

  echo "Creating KMS policy..."
  oc exec -c vault "${pod_name}" -n "${namespace}" -- \
    sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN=${ROOT_TOKEN} vault policy write -namespace=${VAULT_ENTERPRISE_NS} kms-policy - <<POLICY
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

  echo "Creating AppRole role..."
  vault_cli write -namespace="${VAULT_ENTERPRISE_NS}" auth/approle/role/kms-plugin \
    token_policies=kms-policy \
    token_ttl=1h \
    token_max_ttl=4h

  echo "Retrieving AppRole credentials..."
  ROLE_ID=$(vault_cli read -namespace="${VAULT_ENTERPRISE_NS}" -field=role_id auth/approle/role/kms-plugin/role-id)
  SECRET_ID=$(vault_cli write -namespace="${VAULT_ENTERPRISE_NS}" -field=secret_id -f auth/approle/role/kms-plugin/secret-id)

  echo "Creating vault-credentials secret..."
  oc create secret generic vault-credentials \
    --from-literal=role-id="${ROLE_ID}" \
    --from-literal=secret-id="${SECRET_ID}" \
    --from-literal=root-token="${ROOT_TOKEN}" \
    -n "${namespace}" \
    --dry-run=client -o yaml | oc apply -f -

  echo "Vault credentials saved to vault-credentials secret"

  echo ""
  echo "========================================="
  echo "Vault Configuration Complete"
  echo "========================================="
  echo ""
  echo "Summary:"
  echo "  - Vault Service: ${service_name}.${namespace}.svc:8200"
  echo "  - Credentials Secret: vault-credentials (namespace: ${namespace})"
  echo "  - Vault Enterprise Namespace: ${VAULT_ENTERPRISE_NS}"
  echo "  - Transit Key: ${key_name}"
  echo "  - ROLE_ID: ${ROLE_ID}"
  echo ""
}

configure_vault "${VAULT_NAMESPACE}" "${VAULT_KMS_KEY_NAME}" "vault-0"
configure_vault "${VAULT_SECONDARY_NAMESPACE}" "${VAULT_SECONDARY_KMS_KEY_NAME}" "vault-secondary-0"
