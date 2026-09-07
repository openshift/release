#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Must match etcd-encryption-vault-install. Prefer the marker written by install.
vault_dev_mode_enabled() {
  if [[ -f "${SHARED_DIR}/vault-dev-mode" ]]; then
    [[ "$(cat "${SHARED_DIR}/vault-dev-mode")" == "true" ]]
    return
  fi
  case "${VAULT_DEV_MODE:-}" in
    true|TRUE|yes|YES|1)
      return 0
      ;;
    false|FALSE|no|NO|0)
      return 1
      ;;
  esac
  [[ -n "${CLUSTER_TYPE:-}" && "${CLUSTER_TYPE}" == equinix-ocp-metal ]]
}

VAULT_HA_REPLICAS="${VAULT_HA_REPLICAS:-3}"
VAULT_TLS_DIR="/vault/userconfig/vault-tls"
VAULT_INIT_SECRET="vault-init-credentials"
VAULT_JOIN_MAX_RETRIES="${VAULT_JOIN_MAX_RETRIES:-30}"
VAULT_JOIN_RETRY_DELAY="${VAULT_JOIN_RETRY_DELAY:-10}"

vault_exec() {
  local pod_name="$1"
  local namespace="$2"
  shift 2
  oc exec "${pod_name}" -n "${namespace}" -c vault -- \
    env VAULT_ADDR="https://127.0.0.1:8200" VAULT_CACERT="${VAULT_TLS_DIR}/ca.pem" \
    "$@"
}

vault_exec_sh() {
  local pod_name="$1"
  local namespace="$2"
  local command="$3"
  oc exec "${pod_name}" -n "${namespace}" -c vault -- \
    sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=${VAULT_TLS_DIR}/ca.pem ${command}"
}

# Run vault CLI with root token. Dev mode uses plain oc exec; HA uses TLS env.
vault_run() {
  local pod_name="$1"
  local namespace="$2"
  local root_token="$3"
  shift 3
  if vault_dev_mode_enabled; then
    oc exec "${pod_name}" -n "${namespace}" -- \
      env VAULT_TOKEN="${root_token}" "$@"
  else
    vault_exec "${pod_name}" "${namespace}" env VAULT_TOKEN="${root_token}" "$@"
  fi
}

vault_run_sh() {
  local pod_name="$1"
  local namespace="$2"
  local root_token="$3"
  local command="$4"
  if vault_dev_mode_enabled; then
    oc exec "${pod_name}" -n "${namespace}" -- \
      sh -c "VAULT_TOKEN=${root_token} ${command}"
  else
    vault_exec_sh "${pod_name}" "${namespace}" \
      "VAULT_TOKEN=${root_token} ${command}"
  fi
}

# Print and return the full vault status output for a pod.
vault_pod_status_output() {
  local pod_name="$1"
  local namespace="$2"
  vault_exec_sh "${pod_name}" "${namespace}" "vault status 2>&1 || true"
}

vault_pod_is_sealed() {
  local pod_name="$1"
  local namespace="$2"
  local status=""
  local sealed=""

  status="$(vault_pod_status_output "${pod_name}" "${namespace}")"
  echo "Vault status for ${pod_name}:"
  echo "${status}"
  sealed="$(echo "${status}" | awk '/^Sealed/ {print $2; exit}')"
  [[ "${sealed}" == "true" ]]
}

vault_pod_is_initialized() {
  local pod_name="$1"
  local namespace="$2"
  local status=""
  local initialized=""

  status="$(vault_pod_status_output "${pod_name}" "${namespace}")"
  echo "Vault status for ${pod_name}:"
  echo "${status}"
  initialized="$(echo "${status}" | awk '/^Initialized/ {print $2; exit}')"
  [[ "${initialized}" == "true" ]]
}

vault_pod_is_active() {
  local pod_name="$1"
  local namespace="$2"
  local status=""
  local sealed=""
  local ha_mode=""

  status="$(vault_pod_status_output "${pod_name}" "${namespace}")"
  echo "Vault status for ${pod_name}:"
  echo "${status}"
  sealed="$(echo "${status}" | awk '/^Sealed/ {print $2; exit}')"
  ha_mode="$(echo "${status}" | awk '/^HA Mode/ {print $3; exit}')"
  [[ "${sealed}" == "false" && "${ha_mode}" == "active" ]]
}

wait_for_leader_active() {
  local pod_name="$1"
  local namespace="$2"
  local attempt=1

  while [[ "${attempt}" -le "${VAULT_JOIN_MAX_RETRIES}" ]]; do
    if vault_pod_is_active "${pod_name}" "${namespace}"; then
      echo "  ✓ ${pod_name} is active leader"
      return 0
    fi
    echo "  Waiting for ${pod_name} to become active leader (${attempt}/${VAULT_JOIN_MAX_RETRIES})..."
    sleep "${VAULT_JOIN_RETRY_DELAY}"
    attempt=$((attempt + 1))
  done

  echo "Error: ${pod_name} did not become active leader after ${VAULT_JOIN_MAX_RETRIES} attempts"
  exit 1
}

wait_for_pod_joined() {
  local pod_name="$1"
  local namespace="$2"
  local attempt=1

  while [[ "${attempt}" -le "${VAULT_JOIN_MAX_RETRIES}" ]]; do
    if vault_pod_is_initialized "${pod_name}" "${namespace}"; then
      echo "  ✓ ${pod_name} joined Raft cluster"
      return 0
    fi
    echo "  Waiting for ${pod_name} to join Raft cluster (${attempt}/${VAULT_JOIN_MAX_RETRIES})..."
    sleep "${VAULT_JOIN_RETRY_DELAY}"
    attempt=$((attempt + 1))
  done

  echo "Error: ${pod_name} did not join Raft cluster after ${VAULT_JOIN_MAX_RETRIES} attempts"
  exit 1
}

unseal_vault_pod() {
  local pod_name="$1"
  local namespace="$2"
  local unseal_key="$3"

  if ! vault_pod_is_sealed "${pod_name}" "${namespace}"; then
    echo "  ✓ ${pod_name} already unsealed"
    return 0
  fi

  echo "Unsealing ${pod_name}..."
  vault_exec "${pod_name}" "${namespace}" vault operator unseal "${unseal_key}"

  if vault_pod_is_sealed "${pod_name}" "${namespace}"; then
    echo "Error: ${pod_name} is still sealed after unseal"
    exit 1
  fi
  echo "  ✓ ${pod_name} is unsealed"
}

# Followers auto-unseal via Raft replication after joining an unsealed leader.
wait_for_pod_unsealed() {
  local pod_name="$1"
  local namespace="$2"
  local attempt=1

  while [[ "${attempt}" -le "${VAULT_JOIN_MAX_RETRIES}" ]]; do
    if ! vault_pod_is_sealed "${pod_name}" "${namespace}"; then
      echo "  ✓ ${pod_name} is unsealed"
      return 0
    fi
    echo "  Waiting for ${pod_name} to unseal via Raft replication (${attempt}/${VAULT_JOIN_MAX_RETRIES})..."
    sleep "${VAULT_JOIN_RETRY_DELAY}"
    attempt=$((attempt + 1))
  done

  echo "Error: ${pod_name} did not become unsealed after ${VAULT_JOIN_MAX_RETRIES} attempts"
  exit 1
}

# Initialize a Vault HA Raft cluster and unseal each replica.
# Args: $1 = namespace, $2 = Helm release name
# Sets VAULT_ROOT_TOKEN with the root token.
initialize_vault() {
  local namespace="$1"
  local release_name="$2"
  local leader_pod="${release_name}-0"
  local root_token=""
  local unseal_key=""

  echo ""
  echo "========================================="
  echo "Vault Initialization"
  echo "========================================="
  echo "Namespace: ${namespace}"
  echo "Release: ${release_name}"
  echo "Replicas: ${VAULT_HA_REPLICAS}"
  echo ""

  if vault_pod_is_initialized "${leader_pod}" "${namespace}"; then
    echo "Vault already initialized, loading credentials from ${VAULT_INIT_SECRET}..."
    root_token="$(oc get secret "${VAULT_INIT_SECRET}" -n "${namespace}" -o jsonpath='{.data.root-token}' | base64 -d)"
    unseal_key="$(oc get secret "${VAULT_INIT_SECRET}" -n "${namespace}" -o jsonpath='{.data.unseal-key}' | base64 -d | tr -d '\n')"
  else
    echo "Initializing Vault on ${leader_pod}..."
    local init_output=""
    init_output="$(vault_exec "${leader_pod}" "${namespace}" \
      vault operator init -key-shares=1 -key-threshold=1 -format=json)"
    root_token="$(echo "${init_output}" | jq -r '.root_token')"
    unseal_key="$(echo "${init_output}" | jq -r '.unseal_keys_b64[0]' | tr -d '\n')"

    oc create secret generic "${VAULT_INIT_SECRET}" \
      --from-literal=root-token="${root_token}" \
      --from-literal=unseal-key="${unseal_key}" \
      -n "${namespace}" \
      --dry-run=client -o yaml | oc apply -f -
    echo "  ✓ Vault initialized, credentials stored in ${VAULT_INIT_SECRET}"
  fi

  unseal_vault_pod "${leader_pod}" "${namespace}" "${unseal_key}"
  wait_for_leader_active "${leader_pod}" "${namespace}"

  local i pod
  for i in $(seq 1 $((VAULT_HA_REPLICAS - 1))); do
    pod="${release_name}-${i}"
    wait_for_pod_joined "${pod}" "${namespace}"
    wait_for_pod_unsealed "${pod}" "${namespace}"
  done

  echo ""
  echo "Vault cluster is initialized and ready"
  VAULT_ROOT_TOKEN="${root_token}"
}

# Configure a Vault instance for KMS encryption.
# Args: $1 = namespace, $2 = KMS key name, $3 = pod name, $4 = root token
configure_vault_kms() {
  local namespace="$1"
  local key_name="$2"
  local pod_name="$3"
  local root_token="$4"
  local service_name="${pod_name%-0}"
  local mode_suffix=""

  if vault_dev_mode_enabled; then
    mode_suffix=" (dev mode)"
  fi

  echo ""
  echo "========================================="
  echo "Vault Configuration for KMS${mode_suffix}"
  echo "========================================="
  echo "Namespace: ${namespace}"
  echo "Vault Enterprise NS: ${VAULT_ENTERPRISE_NS}"
  echo "KMS Key Name: ${key_name}"
  echo ""

  echo "Configuring Vault for KMS..."
  echo ""

  echo "Creating Vault Enterprise namespace '${VAULT_ENTERPRISE_NS}'..."
  vault_run "${pod_name}" "${namespace}" "${root_token}" \
    vault namespace create "${VAULT_ENTERPRISE_NS}"

  echo "Enabling transit secret engine..."
  vault_run "${pod_name}" "${namespace}" "${root_token}" \
    vault secrets enable -namespace="${VAULT_ENTERPRISE_NS}" -path=transit transit

  echo "Creating transit encryption key..."
  vault_run "${pod_name}" "${namespace}" "${root_token}" \
    vault write -namespace="${VAULT_ENTERPRISE_NS}" -f "transit/keys/${key_name}"

  echo "Enabling AppRole authentication..."
  vault_run "${pod_name}" "${namespace}" "${root_token}" \
    vault auth enable -namespace="${VAULT_ENTERPRISE_NS}" approle

  echo "Creating KMS policy..."
  vault_run_sh "${pod_name}" "${namespace}" "${root_token}" \
    "vault policy write -namespace=${VAULT_ENTERPRISE_NS} kms-policy - <<POLICY
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
  vault_run "${pod_name}" "${namespace}" "${root_token}" \
    vault write -namespace="${VAULT_ENTERPRISE_NS}" auth/approle/role/kms-plugin \
      token_policies=kms-policy \
      token_ttl=1h \
      token_max_ttl=4h

  echo "Retrieving AppRole credentials..."
  ROLE_ID=$(vault_run "${pod_name}" "${namespace}" "${root_token}" \
    vault read -namespace="${VAULT_ENTERPRISE_NS}" -field=role_id auth/approle/role/kms-plugin/role-id)
  SECRET_ID=$(vault_run "${pod_name}" "${namespace}" "${root_token}" \
    vault write -namespace="${VAULT_ENTERPRISE_NS}" -field=secret_id -f auth/approle/role/kms-plugin/secret-id)

  echo "Creating vault-credentials secret..."
  oc create secret generic vault-credentials \
    --from-literal=role-id="${ROLE_ID}" \
    --from-literal=secret-id="${SECRET_ID}" \
    --from-literal=root-token="${root_token}" \
    -n "${namespace}"

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

if vault_dev_mode_enabled; then
  echo "Vault configure mode: dev (skipping init/unseal)"
  configure_vault_kms "${VAULT_NAMESPACE}" "${VAULT_KMS_KEY_NAME}" "vault-0" "root"
  configure_vault_kms "${VAULT_SECONDARY_NAMESPACE}" "${VAULT_SECONDARY_KMS_KEY_NAME}" "vault-secondary-0" "root"
else
  echo "Vault configure mode: HA Raft"
  initialize_vault "${VAULT_NAMESPACE}" "vault"
  configure_vault_kms "${VAULT_NAMESPACE}" "${VAULT_KMS_KEY_NAME}" "vault-0" "${VAULT_ROOT_TOKEN}"

  initialize_vault "${VAULT_SECONDARY_NAMESPACE}" "vault-secondary"
  configure_vault_kms "${VAULT_SECONDARY_NAMESPACE}" "${VAULT_SECONDARY_KMS_KEY_NAME}" "vault-secondary-0" "${VAULT_ROOT_TOKEN}"
fi
