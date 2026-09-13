#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

VAULT_SECRET_UNSEAL_KEY_PATH="/vault/secrets/unseal/unseal-key"
VAULT_SECRET_ROOT_TOKEN_PATH="/vault/secrets/root/token"

# Configure a Vault instance for KMS encryption.
# Args: $1 = namespace, $2 = KMS key name, $3 = pod name
configure_vault() {
  local namespace="$1"
  local key_name="$2"
  local pod_name="$3"
  local service_name="${pod_name%-0}"

  # Disable tracing due to password handling
  local WAS_TRACING=false
  [[ $- == *x* ]] && WAS_TRACING=true
  set +x
  local ROOT_TOKEN
  ROOT_TOKEN="$(oc get secret vault-root-token -n "${namespace}" -o jsonpath='{.data.token}' | base64 -d)"
  if [[ "${WAS_TRACING}" == true ]]; then
    set -x
  fi

  vault_cli() {
    local was_tracing=false
    [[ $- == *x* ]] && was_tracing=true
    set +x
    oc exec -c vault "${pod_name}" -n "${namespace}" -- \
      sh -ec "export VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=\"\$(cat '${VAULT_SECRET_ROOT_TOKEN_PATH}')\"
exec vault \"\$@\"" sh "$@"
    local rc=$?
    if [[ "${was_tracing}" == true ]]; then
      set -x
    fi
    return "${rc}"
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
    oc exec -c vault "${pod_name}" -n "${namespace}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      sh -c "test -s '${VAULT_SECRET_UNSEAL_KEY_PATH}' && vault operator unseal \"\$(cat '${VAULT_SECRET_UNSEAL_KEY_PATH}')\" >/dev/null"
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

  if ! oc exec -c vault "${pod_name}" -n "${namespace}" -- test -s "${VAULT_SECRET_ROOT_TOKEN_PATH}"; then
    echo "Error: ${VAULT_SECRET_ROOT_TOKEN_PATH} is not mounted in ${pod_name}"
    exit 1
  fi

  echo "Creating Vault Enterprise namespace '${VAULT_ENTERPRISE_NS}'..."
  vault_cli_ok_if_exists namespace create "${VAULT_ENTERPRISE_NS}"

  echo "Enabling transit secret engine..."
  vault_cli_ok_if_exists secrets enable -namespace="${VAULT_ENTERPRISE_NS}" -path=transit transit

  echo "Creating transit encryption key..."
  vault_cli_ok_if_exists write -namespace="${VAULT_ENTERPRISE_NS}" -f "transit/keys/${key_name}"

  echo "Enabling AppRole authentication..."
  vault_cli_ok_if_exists auth enable -namespace="${VAULT_ENTERPRISE_NS}" approle

  echo "Creating KMS policy..."
  local was_tracing=false
  [[ $- == *x* ]] && was_tracing=true
  set +x
  oc exec -i -c vault "${pod_name}" -n "${namespace}" -- \
    sh -ec "export VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=\"\$(cat '${VAULT_SECRET_ROOT_TOKEN_PATH}')\"
exec vault policy write -namespace='${VAULT_ENTERPRISE_NS}' kms-policy -" <<POLICY
path "transit/encrypt/${key_name}" {
  capabilities = ["update"]
}
path "transit/decrypt/${key_name}" {
  capabilities = ["update"]
}
path "transit/keys/${key_name}" {
  capabilities = ["read"]
}
path "sys/license/status" {
  capabilities = ["read"]
}
POLICY
  if [[ "${was_tracing}" == true ]]; then
    set -x
  fi

  echo "Creating AppRole role..."
  vault_cli write -namespace="${VAULT_ENTERPRISE_NS}" auth/approle/role/kms-plugin \
    token_policies=kms-policy \
    token_ttl=1h \
    token_max_ttl=4h

  echo "Retrieving AppRole credentials..."
  local was_tracing=false
  [[ $- == *x* ]] && was_tracing=true
  set +x
  ROLE_ID=$(vault_cli read -namespace="${VAULT_ENTERPRISE_NS}" -field=role_id auth/approle/role/kms-plugin/role-id)
  SECRET_ID=$(vault_cli write -namespace="${VAULT_ENTERPRISE_NS}" -field=secret_id -f auth/approle/role/kms-plugin/secret-id)

  echo "Creating vault-credentials secret..."
  oc create secret generic vault-credentials \
    --from-literal=role-id="${ROLE_ID}" \
    --from-literal=secret-id="${SECRET_ID}" \
    --from-literal=root-token="${ROOT_TOKEN}" \
    -n "${namespace}" \
    --dry-run=client -o yaml | oc apply -f -
  local role_id_summary="${ROLE_ID}"
  unset ROLE_ID SECRET_ID
  if [[ "${was_tracing}" == true ]]; then
    set -x
  fi

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
  echo "  - ROLE_ID: ${role_id_summary}"
  echo ""
}

configure_vault "${VAULT_NAMESPACE}" "${VAULT_KMS_KEY_NAME}" "vault-0"
configure_vault "${VAULT_SECONDARY_NAMESPACE}" "${VAULT_SECONDARY_KMS_KEY_NAME}" "vault-secondary-0"
