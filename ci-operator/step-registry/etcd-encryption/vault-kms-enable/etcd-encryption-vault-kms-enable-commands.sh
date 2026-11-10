#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

date -u "+%Y-%m-%dT%H:%M:%SZ"
[ -f "${SHARED_DIR}/proxy-conf.sh" ] && source "${SHARED_DIR}/proxy-conf.sh"

APISERVER_ENCRYPTION_PATCH='{"spec":{"encryption":{"type":"KMS","kms":{"pluginConfig":{"apiVersion":"kms.hashicorp.com/v1","resource":"vaultkmsconfigs","name":"'"${VAULT_KMS_CONFIG_NAME}"'"}}}}}'

# 1. Apply the VaultKMSConfig CRD that the APIServer encryption config
#    references (kms.hashicorp.com/v1). Inline the manifest the same way
#    etcd-encryption-vault-configure does: sibling files are not shipped into
#    the step pod, and curling an external URL is fragile.
#    Idempotent if vault-configure already applied it.
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


# 2. Let the cluster settle after installation before patching the APIServer
#    config, so the patch does not race transient API instability and no retry
#    is needed.
oc adm wait-for-stable-cluster --minimum-stable-period=30s --timeout=20m

# 3. Enable KMS etcd encryption on the APIServer config.
oc patch apiserver cluster --type merge -p "${APISERVER_ENCRYPTION_PATCH}"
echo "INFO - KMS encryption enabled on APIServer cluster"

# 4. Wait for every apiserver operator to finish migrating its resources, the
#    same operators the kas-o encryption e2e suites cover. Start with a 30
#    minute budget; raise only if CI shows migrations regularly exceeding it.
TIMEOUT_MINUTES=30
DEADLINE=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
EXPECTED_OPERATORS=3
while true; do
  COMPLETED=0
  for resource in kubeapiservers.operator.openshift.io openshiftapiservers.operator.openshift.io authentications.operator.openshift.io; do
    REASON="$(oc get "${resource}" cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")].reason}' 2>/dev/null || true)"
    if [[ "${REASON}" == "EncryptionCompleted" ]]; then
      COMPLETED=$((COMPLETED + 1))
    else
      echo "INFO - ${resource}: Encrypted=${REASON:-<unset>}, waiting for migration to complete"
    fi
  done
  if [[ "${COMPLETED}" -eq "${EXPECTED_OPERATORS}" ]]; then
    echo "INFO - all apiserver operators report Encrypted reason=EncryptionCompleted"
    break
  fi
  if [[ "$(date +%s)" -gt "${DEADLINE}" ]]; then
    echo "ERROR: timed out after ${TIMEOUT_MINUTES}m waiting for the Encrypted conditions" >&2
    exit 1
  fi
  sleep 30
done

# 5. Let the cluster settle before the job continues (e.g. before an upgrade).
oc adm wait-for-stable-cluster --minimum-stable-period=30s --timeout=20m

date -u "+%Y-%m-%dT%H:%M:%SZ"
echo "INFO - KMS etcd encryption enabled and migration completed"
