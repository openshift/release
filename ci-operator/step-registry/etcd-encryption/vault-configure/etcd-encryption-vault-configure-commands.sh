#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

VAULT_SECRET_ROOT_TOKEN_PATH="/vault/secrets/root/token"
VAULT_KMS_CONFIG_OPENSHIFT_NS="openshift-config"

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

# Same resolution order as resolve_vault_kms_plugin_image (env, then SHARED_DIR).
# Optional: empty when unset (only encryption-kms-2 jobs set VAULT_KMS_PLUGIN_IMAGE_UPDATE).
resolve_vault_kms_plugin_update_image() {
  if [[ -n "${VAULT_KMS_PLUGIN_IMAGE_UPDATE:-}" ]]; then
    echo "${VAULT_KMS_PLUGIN_IMAGE_UPDATE}"
    return
  fi
  if [[ -f "${SHARED_DIR}/vault-kms-plugin-image-update" ]]; then
    tr -d '[:space:]' < "${SHARED_DIR}/vault-kms-plugin-image-update"
    return
  fi
}

# Inline the manifest because sibling files are not shipped into the step pod.
install_vault_kms_config_crd_v1() {
  echo "Installing VaultKMSConfig CRD (kms.hashicorp.com/v1)..."
  oc apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.21.0
  creationTimestamp: null
  name: vaultkmsconfigs.kms.hashicorp.com
spec:
  group: kms.hashicorp.com
  names:
    kind: VaultKMSConfig
    listKind: VaultKMSConfigList
    plural: vaultkmsconfigs
    singular: vaultkmsconfig
  scope: Cluster
  versions:
  - name: v1
    schema:
      openAPIV3Schema:
        properties:
          apiVersion:
            description: |-
              APIVersion defines the versioned schema of this representation of an object.
              Servers should convert recognized schemas to the latest internal value, and
              may reject unrecognized values.
              More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
            type: string
          kind:
            description: |-
              Kind is a string value representing the REST resource this object represents.
              Servers may infer this from the endpoint the client submits requests to.
              Cannot be updated.
              In CamelCase.
              More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
            type: string
          metadata:
            type: object
          spec:
            description: VaultKMSConfigSpec defines the desired state of VaultKMSConfig.
            properties:
              authentication:
                description: authentication defines the authentication method used
                  to authenticate with Vault.
                properties:
                  appRole:
                    description: |-
                      appRole defines the configuration for AppRole authentication.
                      This field must be set when type is AppRole, and must be unset otherwise.
                    properties:
                      secret:
                        description: |-
                          secret references a secret in the openshift-config namespace containing
                          the AppRole credentials used to authenticate with Vault.
                          The referenced Secret must contain two keys: "role-id" for the AppRole Role ID and "secret-id" for the AppRole Secret ID.
                        properties:
                          name:
                            description: |-
                              name is the metadata.name of the referenced secret in the openshift-config namespace.
                              The name must be a valid DNS subdomain name: it must contain no more than 253 characters,
                              contain only lowercase alphanumeric characters, '-' or '.', and start and end with an alphanumeric character.
                            maxLength: 253
                            minLength: 1
                            type: string
                            x-kubernetes-validations:
                            - message: 'name must be a valid DNS subdomain name: contain
                                no more than 253 characters, contain only lowercase
                                alphanumeric characters, ''-'' or ''.'', and start
                                and end with an alphanumeric character'
                              rule: self.matches('^[a-z0-9]([a-z0-9\\-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9\\-]*[a-z0-9])?)*$')
                        required:
                        - name
                        type: object
                    required:
                    - secret
                    type: object
                  type:
                    description: |-
                      type defines the authentication method used to authenticate with Vault.
                      Allowed values are AppRole.
                      When set to AppRole, the plugin uses AppRole credentials to authenticate with Vault.
                    enum:
                    - AppRole
                    type: string
                required:
                - type
                type: object
                x-kubernetes-validations:
                - message: appRole config is required when authentication type is
                    AppRole, and forbidden otherwise
                  rule: 'self.type == ''AppRole'' ? has(self.appRole) : !has(self.appRole)'
              tls:
                description: |-
                  tls contains the TLS configuration for connecting to the Vault server.
                  When this field is not set, system default TLS settings are used.
                minProperties: 1
                properties:
                  caBundle:
                    description: |-
                      caBundle references a ConfigMap in the openshift-config namespace containing
                      the CA certificate bundle used to verify the TLS connection to the Vault server.
                      The referenced ConfigMap must contain the CA bundle in the key "ca-bundle.crt".
                      When this field is not set, the system's trusted CA certificates are used.

                      The namespace for the ConfigMap is openshift-config.

                      Example ConfigMap:
                        apiVersion: v1
                        kind: ConfigMap
                        metadata:
                          name: vault-ca-bundle
                          namespace: openshift-config
                        data:
                          ca-bundle.crt: |
                            -----BEGIN CERTIFICATE-----
                            ...
                            -----END CERTIFICATE-----
                    properties:
                      name:
                        description: |-
                          name is the metadata.name of the referenced ConfigMap in the openshift-config namespace.
                          The name must be a valid DNS subdomain name: it must contain no more than 253 characters,
                          contain only lowercase alphanumeric characters, '-' or '.', and start and end with an alphanumeric character.
                        maxLength: 253
                        minLength: 1
                        type: string
                        x-kubernetes-validations:
                        - message: 'name must be a valid DNS subdomain name: contain
                            no more than 253 characters, contain only lowercase alphanumeric
                            characters, ''-'' or ''.'', and start and end with an
                            alphanumeric character'
                          rule: self.matches('^[a-z0-9]([a-z0-9\\-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9\\-]*[a-z0-9])?)*$')
                    required:
                    - name
                    type: object
                  serverName:
                    description: |-
                      serverName specifies the Server Name Indication (SNI) to use when connecting to Vault via TLS.
                      This is useful when the Vault server's hostname doesn't match its TLS certificate.
                      When this field is not set, the hostname from vaultAddress is used for SNI.

                      The value must be a valid DNS hostname: it must contain no more than 253 characters,
                      contain only lowercase alphanumeric characters, '-' or '.', and start and end with an alphanumeric character.
                    maxLength: 253
                    minLength: 1
                    type: string
                    x-kubernetes-validations:
                    - message: 'serverName must be a valid DNS hostname: contain no
                        more than 253 characters, contain only lowercase alphanumeric
                        characters, ''-'' or ''.'', and start and end with an alphanumeric
                        character'
                      rule: self.matches('^[a-z0-9]([a-z0-9\\-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9\\-]*[a-z0-9])?)*$')
                type: object
              vaultAddress:
                description: |-
                  vaultAddress specifies the address of the HashiCorp Vault instance.
                  The value must be a valid HTTPS URL containing only scheme, host, and optional port.
                  Paths, user info, query parameters, and fragments are not allowed.

                  Format: https://hostname[:port]
                  Example: https://vault.example.com:8200

                  The value must be between 1 and 512 characters.
                maxLength: 512
                minLength: 1
                type: string
                x-kubernetes-validations:
                - message: must be a valid URL
                  rule: isURL(self)
                - message: must use the 'https' scheme
                  rule: isURL(self) && url(self).getScheme() == 'https'
                - message: must not contain a path
                  rule: isURL(self) && (url(self).getEscapedPath() == '' || url(self).getEscapedPath()
                    == '/')
                - message: must not have a query
                  rule: isURL(self) && url(self).getQuery() == {}
                - message: must not have a fragment
                  rule: self.find('#(.+)$') == ''
                - message: must not have user info
                  rule: self.find('@') == ''
              vaultAuthNamespace:
                description: |-
                  vaultAuthNamespace specifies the Vault namespace to use for authentication.
                  This is only applicable for Vault Enterprise installations where authentication
                  and Transit operations may be in different namespaces.
                  When this field is not set, the value of vaultNamespace is used for both
                  authentication and Transit key operations.

                  The value must be between 1 and 4096 characters.
                  The namespace cannot end with a forward slash, cannot contain spaces, and cannot be one of the reserved strings: root, sys, audit, auth, cubbyhole, or identity.
                maxLength: 4096
                minLength: 1
                type: string
                x-kubernetes-validations:
                - message: vaultAuthNamespace cannot end with a forward slash
                  rule: '!self.endsWith(''/'')'
                - message: vaultAuthNamespace cannot contain spaces
                  rule: '!self.contains('' '')'
                - message: vaultAuthNamespace cannot be a reserved string (root, sys,
                    audit, auth, cubbyhole, identity)
                  rule: '!(self in [''root'', ''sys'', ''audit'', ''auth'', ''cubbyhole'',
                    ''identity''])'
              vaultKeyPath:
                description: |-
                  vaultKeyPath specifies the full path to the encryption key in Vault's Transit secrets engine,
                  combining the Transit engine mount path and the key name separated by "/keys/".
                  Format: <mount>/keys/<key-name> (e.g., transit/keys/my-key, myteam/transit/keys/production-key).

                  The total path length must be between 8 and 1542 characters.
                  The path cannot start or end with a forward slash, cannot contain consecutive forward slashes,
                  must only contain RFC 3986 unreserved characters (alphanumeric, hyphen, period, underscore, tilde)
                  and forward slashes as path separators, and must not contain "." or ".." path segments.
                  The key name must start and end with an alphanumeric character or underscore, and may contain
                  alphanumeric characters, underscores, hyphens, and periods in the middle.
                maxLength: 1542
                minLength: 8
                type: string
                x-kubernetes-validations:
                - message: vaultKeyPath cannot start with a forward slash
                  rule: '!self.startsWith(''/'')'
                - message: vaultKeyPath cannot end with a forward slash
                  rule: '!self.endsWith(''/'')'
                - message: vaultKeyPath cannot contain consecutive forward slashes
                  rule: '!self.contains(''//'')'
                - message: vaultKeyPath must only contain RFC 3986 unreserved characters
                    (alphanumeric, hyphen, period, underscore, tilde) and forward
                    slashes
                  rule: self.matches('^[a-zA-Z0-9._~/-]+$')
                - message: vaultKeyPath must not contain '.' or '..' path segments
                  rule: self.split('/').filter(s, s == '.' || s == '..').size() ==
                    0
                - message: vaultKeyPath must follow the format <mount>/keys/<key-name>
                    where the key name starts and ends with an alphanumeric character
                    or underscore and may contain alphanumeric characters, underscores,
                    hyphens, and periods
                  rule: self.matches('^[a-zA-Z0-9._~-]+(/[a-zA-Z0-9._~-]+)*/keys/[a-zA-Z0-9_]([a-zA-Z0-9_.-]*[a-zA-Z0-9_])?$')
              vaultNamespace:
                description: |-
                  vaultNamespace specifies the Vault namespace where the Transit secrets engine is mounted.
                  This is only applicable for Vault Enterprise installations.
                  When this field is not set, no namespace is used.

                  The value must be between 1 and 4096 characters.
                  The namespace cannot end with a forward slash, cannot contain spaces, and cannot be one of the reserved strings: root, sys, audit, auth, cubbyhole, or identity.
                maxLength: 4096
                minLength: 1
                type: string
                x-kubernetes-validations:
                - message: vaultNamespace cannot end with a forward slash
                  rule: '!self.endsWith(''/'')'
                - message: vaultNamespace cannot contain spaces
                  rule: '!self.contains('' '')'
                - message: vaultNamespace cannot be a reserved string (root, sys,
                    audit, auth, cubbyhole, identity)
                  rule: '!(self in [''root'', ''sys'', ''audit'', ''auth'', ''cubbyhole'',
                    ''identity''])'
            required:
            - authentication
            - vaultAddress
            - vaultKeyPath
            type: object
          status:
            description: VaultKMSConfigStatus defines the observed state of VaultKMSConfig.
            properties:
              kmsPluginImage:
                description: |-
                  kmsPluginImage is the resolved container image for the HashiCorp Vault KMS plugin,
                  set by the controller. This may be a tag-based or digest-based image reference.
                type: string
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
EOF
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
  # Bracket IPv6 so https://fd02::1:8200 becomes https://[fd02::1]:8200 (valid URL).
  if [[ "${cluster_ip}" == *:* ]]; then
    cluster_ip="[${cluster_ip}]"
  fi
  echo "https://${cluster_ip}:${port}"
}

# Apply a cluster VaultKMSConfig on the new kms.hashicorp.com/v1 API.
apply_vault_kms_config_v1() {
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
apiVersion: kms.hashicorp.com/v1
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
  echo "Setting VaultKMSConfig ${cr_name} status.kmsPluginImage (normally set by the operator)..."
  oc patch vaultkmsconfigs.kms.hashicorp.com "${cr_name}" --type=merge --subresource=status \
    -p "$(jq -n --arg img "${plugin_image}" '{status:{kmsPluginImage:$img}}')"
}

wait_for_vault_api() {
  local namespace="$1"
  local pod_name="$2"
  local i=0
  local status_rc=0

  echo "Waiting for Vault API on ${pod_name}..."
  while [[ "${i}" -lt 60 ]]; do
    set +e
    oc exec -c vault "${pod_name}" -n "${namespace}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault status >/dev/null 2>&1
    status_rc=$?
    set -e
    # 0 = unsealed, 2 = sealed; both mean the TLS listener is up.
    if [[ "${status_rc}" -eq 0 || "${status_rc}" -eq 2 ]]; then
      return "${status_rc}"
    fi
    i=$((i + 1))
    sleep 5
  done

  echo "Timed out waiting for Vault API on ${pod_name} (last vault status exit code: ${status_rc})"
  oc get "pod/${pod_name}" -n "${namespace}" -o wide || true
  oc logs -c vault "${pod_name}" -n "${namespace}" --tail=80 || true
  return "${status_rc}"
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

    echo "Waiting for ${pod_name} to be Ready..."
    oc wait --for=condition=ready "pod/${pod_name}" -n "${namespace}" --timeout=5m

    status_rc=0
    wait_for_vault_api "${namespace}" "${pod_name}"
    status_rc=$?

    if [[ "${status_rc}" -eq 0 ]]; then
      return 0
    fi

    if [[ "${status_rc}" -ne 2 ]]; then
      return "${status_rc}"
    fi

    echo "Vault is sealed; unsealing with stored key..."
    local was_tracing=false
    [[ $- == *x* ]] && was_tracing=true
    set +x
    local unseal_key
    unseal_key="$(oc get secret vault-unseal-key -n "${namespace}" -o jsonpath='{.data.unseal-key}' | base64 -d)"
    if [[ "${was_tracing}" == true ]]; then
      set -x
    fi
    [[ -n "${unseal_key}" ]] || {
      echo "Error: vault-unseal-key secret is empty in ${namespace}"
      return 1
    }
    oc exec -c vault "${pod_name}" -n "${namespace}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault operator unseal "${unseal_key}" >/dev/null
    unset unseal_key

    set +e
    oc exec -c vault "${pod_name}" -n "${namespace}" -- \
      env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
      vault status >/dev/null 2>&1
    status_rc=$?
    set -e
    if [[ "${status_rc}" -ne 0 ]]; then
      echo "Vault is not unsealed after unseal attempt (vault status exit code: ${status_rc})"
      oc logs -c vault "${pod_name}" -n "${namespace}" --tail=80 || true
      return "${status_rc}"
    fi
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
  apply_vault_kms_config_v1 "${namespace}-v1" "${service_name}" "${namespace}" "${key_name}" "${ca_bundle_name}" "${approle_secret_name}"
}

install_vault_kms_config_crd_v1

# Persist update image the same way install records VAULT_KMS_PLUGIN_IMAGE into SHARED_DIR
# (env wins; otherwise keep the file written by etcd-encryption-vault-install).
plugin_update_image="$(resolve_vault_kms_plugin_update_image)"
if [[ -n "${plugin_update_image}" ]]; then
  echo "Vault KMS plugin update image: ${plugin_update_image}"
  echo "${plugin_update_image}" > "${SHARED_DIR}/vault-kms-plugin-image-update"
fi

configure_vault "${VAULT_NAMESPACE}" "${VAULT_KMS_KEY_NAME}" "vault-0" "vault-ca-bundle" "vault-approle-secret"
configure_vault "${VAULT_SECONDARY_NAMESPACE}" "${VAULT_SECONDARY_KMS_KEY_NAME}" "vault-secondary-0" "vault-ca-bundle-secondary" "vault-approle-secret-secondary"
