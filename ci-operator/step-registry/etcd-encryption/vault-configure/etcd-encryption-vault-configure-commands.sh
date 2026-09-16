#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

VAULT_SECRET_UNSEAL_KEY_PATH="/vault/secrets/unseal/unseal-key"
VAULT_SECRET_ROOT_TOKEN_PATH="/vault/secrets/root/token"
VAULT_KMS_CONFIG_OPENSHIFT_NS="openshift-config"
VAULT_KMS_CONFIG_CRD_URL="https://raw.githubusercontent.com/kevinrizza/vault-kms-plugin-openshift-provider/main/bundle/manifests/kms.openshift.io_vaultkmsconfigs.yaml"

resolve_vault_kms_plugin_image() {
  if [[ -n "${VAULT_KMS_PLUGIN_IMAGE:-}" ]]; then
    echo "${VAULT_KMS_PLUGIN_IMAGE}"
    return
  fi
  if [[ -f "${SHARED_DIR}/vault-kms-plugin-image" ]]; then
    tr -d '[:space:]' < "${SHARED_DIR}/vault-kms-plugin-image"
    return
  fi
  echo "Error: set VAULT_KMS_PLUGIN_IMAGE or run etcd-encryption-vault-install first" >&2
  exit 1
}

install_vault_kms_config_crd() {
  echo "Installing VaultKMSConfig CRD (mock operator API)..."
  curl -fsSL "${VAULT_KMS_CONFIG_CRD_URL}" | oc apply -f -
}

# Create or update a generic secret from env-file lines on stdin (avoids --from-literal argv leaks).
apply_opaque_secret_from_stdin() {
  local secret_name="$1"
  local namespace="$2"
  oc create secret generic "${secret_name}" \
    --from-env-file=/dev/stdin \
    -n "${namespace}" \
    --dry-run=client -o yaml | oc apply -f -
}

# Copy AppRole credentials to openshift-config for VaultKMSConfig (library-go test helper).
ensure_vault_approle_secret() {
  local vault_namespace="$1"
  local secret_name="$2"
  local role_id=""
  local secret_id=""

  echo "Creating AppRole secret ${secret_name} in ${VAULT_KMS_CONFIG_OPENSHIFT_NS}..."
  local was_tracing=false
  [[ $- == *x* ]] && was_tracing=true
  set +x
  role_id="$(oc get secret vault-credentials -n "${vault_namespace}" -o jsonpath='{.data.role-id}' | base64 -d)"
  secret_id="$(oc get secret vault-credentials -n "${vault_namespace}" -o jsonpath='{.data.secret-id}' | base64 -d)"
  {
    printf 'role-id=%s\n' "${role_id}"
    printf 'secret-id=%s\n' "${secret_id}"
  } | apply_opaque_secret_from_stdin "${secret_name}" "${VAULT_KMS_CONFIG_OPENSHIFT_NS}"
  unset role_id secret_id
  if [[ "${was_tracing}" == true ]]; then
    set -x
  fi
}

# kube-apiserver uses host-network DNS and cannot resolve cluster Service names; use ClusterIP
# (same as library-go getVaultServiceAddress in test/library/encryption/kms/vault.go).
resolve_vault_service_address() {
  local vault_namespace="$1"
  local service_name="$2"
  local cluster_ip=""
  local port=""

  cluster_ip="$(oc get svc "${service_name}" -n "${vault_namespace}" -o jsonpath='{.spec.clusterIP}')"
  if [[ -z "${cluster_ip}" || "${cluster_ip}" == "None" ]]; then
    echo "Error: Service ${service_name} in ${vault_namespace} has no ClusterIP" >&2
    exit 1
  fi
  port="$(oc get svc "${service_name}" -n "${vault_namespace}" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')"
  if [[ -z "${port}" ]]; then
    echo "Error: Service ${service_name} in ${vault_namespace} has no port named https" >&2
    exit 1
  fi
  echo "https://${cluster_ip}:${port}"
}

# Apply a cluster VaultKMSConfig matching library-go test/library/encryption/kms/vault.go defaults.
apply_vault_kms_config() {
  local cr_name="$1"
  local service_name="$2"
  local vault_namespace="$3"
  local key_name="$4"
  local ca_bundle_name="$5"
  local approle_secret_name="$6"
  local vault_address=""
  local server_name="${service_name}.${vault_namespace}.svc"
  local vault_key_path="transit/keys/${key_name}"
  local plugin_image=""

  vault_address="$(resolve_vault_service_address "${vault_namespace}" "${service_name}")"
  echo "Resolved Vault address for ${cr_name}: ${vault_address} (serverName: ${server_name})"

  echo "Applying VaultKMSConfig ${cr_name}..."
  oc apply -f - <<EOF
apiVersion: kms.openshift.io/v1alpha1
kind: VaultKMSConfig
metadata:
  name: ${cr_name}
spec:
  vaultAddress: ${vault_address}
  vaultNamespace: ${VAULT_ENTERPRISE_NS}
  vaultKeyPath: ${vault_key_path}
  authentication:
    type: AppRole
    appRole:
      secret:
        name: ${approle_secret_name}
  tls:
    caBundle:
      name: ${ca_bundle_name}
    serverName: ${server_name}
EOF

  plugin_image="$(resolve_vault_kms_plugin_image)"
  echo "Setting VaultKMSConfig status.kmsPluginImage (normally set by the operator)..."
  oc patch vaultkmsconfig "${cr_name}" --type=merge --subresource=status \
    -p "$(jq -n --arg img "${plugin_image}" '{status:{kmsPluginImage:$img}}')"
}

# Configure a Vault instance for KMS encryption.
# Args: $1 = namespace, $2 = KMS key name, $3 = pod name, $4 = CA ConfigMap name in openshift-config,
#       $5 = AppRole secret name in openshift-config
configure_vault() {
  local namespace="$1"
  local key_name="$2"
  local pod_name="$3"
  local ca_bundle_name="$4"
  local approle_secret_name="$5"
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
  {
    printf 'role-id=%s\n' "${ROLE_ID}"
    printf 'secret-id=%s\n' "${SECRET_ID}"
    printf 'root-token=%s\n' "${ROOT_TOKEN}"
  } | apply_opaque_secret_from_stdin vault-credentials "${namespace}"
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

  ensure_vault_approle_secret "${namespace}" "${approle_secret_name}"
  apply_vault_kms_config "${namespace}" "${service_name}" "${namespace}" "${key_name}" "${ca_bundle_name}" "${approle_secret_name}"
}

install_vault_kms_config_crd

configure_vault "${VAULT_NAMESPACE}" "${VAULT_KMS_KEY_NAME}" "vault-0" "vault-ca-bundle" "vault-approle-secret"
configure_vault "${VAULT_SECONDARY_NAMESPACE}" "${VAULT_SECONDARY_KMS_KEY_NAME}" "vault-secondary-0" "vault-ca-bundle-secondary" "vault-approle-secret-secondary"
