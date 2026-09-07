#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Dev mode is used on bare metal by default (no Raft HA / init-unseal complexity).
# Set VAULT_DEV_MODE=false on metal jobs to force HA Raft, or VAULT_DEV_MODE=true elsewhere.
vault_dev_mode_enabled() {
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

resolve_image_repo() {
  local image="$1"
  if [[ "${image}" == *@* ]]; then
    echo "${image%%@*}"
  else
    echo "${image%:*}"
  fi
}

resolve_image_tag() {
  local image="$1"
  if [[ "${image}" == *@* ]]; then
    echo "${image##*@}"
  else
    echo "${image##*:}"
  fi
}

resolve_image_mirror_destination() {
  local local_repo="$1"
  local image="$2"
  if [[ "${image}" == *@* ]]; then
    # oc image mirror requires a tag on DST or a blank tag to push by digest only.
    echo "${local_repo}"
  else
    echo "${local_repo}:$(resolve_image_tag "${image}")"
  fi
}

record_vault_images() {
  if [[ -z "${VAULT_ENTERPRISE_IMAGE:-}" ]]; then
    echo "Error: VAULT_ENTERPRISE_IMAGE is required"
    exit 1
  fi
  if [[ -z "${VAULT_KMS_PLUGIN_IMAGE:-}" ]]; then
    echo "Error: VAULT_KMS_PLUGIN_IMAGE is required"
    exit 1
  fi

  VAULT_IMAGE_REPOSITORY="$(resolve_image_repo "${VAULT_ENTERPRISE_IMAGE}")"
  VAULT_VERSION="$(resolve_image_tag "${VAULT_ENTERPRISE_IMAGE}")"
  export VAULT_IMAGE_REPOSITORY VAULT_VERSION

  echo "Vault Enterprise image: ${VAULT_ENTERPRISE_IMAGE}"
  echo "  Helm repository: ${VAULT_IMAGE_REPOSITORY}"
  echo "  Helm tag: ${VAULT_VERSION}"
  echo "  ICSP source: $(resolve_image_repo "${VAULT_ENTERPRISE_IMAGE}")"
  echo "${VAULT_ENTERPRISE_IMAGE}" > "${SHARED_DIR}/vault-enterprise-image"

  echo "Vault KMS plugin image: ${VAULT_KMS_PLUGIN_IMAGE}"
  echo "  ICSP source: $(resolve_image_repo "${VAULT_KMS_PLUGIN_IMAGE}")"
  if [[ "${VAULT_KMS_PLUGIN_IMAGE}" == *@* ]]; then
    echo "  local mirror: push by digest to localimages/vault-kube-kms"
  fi
  echo "${VAULT_KMS_PLUGIN_IMAGE}" > "${SHARED_DIR}/vault-kms-plugin-image"
}

mirror_vault_images() {
  local vault_enterprise_src="${VAULT_ENTERPRISE_IMAGE}"
  local vault_enterprise_dst
  local vault_kms_src="${VAULT_KMS_PLUGIN_IMAGE}"
  local vault_kms_dst
  vault_enterprise_dst="$(resolve_image_mirror_destination "${DS_REGISTRY}/localimages/vault-enterprise" "${VAULT_ENTERPRISE_IMAGE}")"
  vault_kms_dst="$(resolve_image_mirror_destination "${DS_REGISTRY}/localimages/vault-kube-kms" "${VAULT_KMS_PLUGIN_IMAGE}")"

  echo "Mirroring vault images to local registry..."
  echo "  ${vault_enterprise_src} -> ${vault_enterprise_dst}"
  echo "  ${vault_kms_src} -> ${vault_kms_dst}"

  # shellcheck disable=SC2087
  ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -euo pipefail

MAX_RETRIES=3
CURRENT_RETRY=1
SUCCESS=false

function run-vault-image-mirror() {
  oc image mirror --keep-manifest-list=true --registry-config ${DS_WORKING_DIR}/pull_secret.json \
    "${vault_enterprise_src}" "${vault_enterprise_dst}" || return 1
  oc image mirror --keep-manifest-list=true --registry-config ${DS_WORKING_DIR}/pull_secret.json \
    "${vault_kms_src}" "${vault_kms_dst}" || return 1
}

while [ \$SUCCESS = false ] && [ \$CURRENT_RETRY -le \$MAX_RETRIES ]; do
  echo "Mirroring vault images attempt \$CURRENT_RETRY"
  run-vault-image-mirror
  if [ \$? -eq 0 ]; then
    SUCCESS=true
  else
    echo "Mirroring vault images attempt \$CURRENT_RETRY failed. Trying again..."
    CURRENT_RETRY=\$(( CURRENT_RETRY + 1 ))
    sleep 5
  fi
done

if [ \$SUCCESS = false ]; then
  echo "Mirroring vault images failed after \$MAX_RETRIES attempts."
  exit 1
fi
EOF

  VAULT_IMAGE_REPOSITORY="${DS_REGISTRY}/localimages/vault-enterprise"
  export VAULT_IMAGE_REPOSITORY
  echo "Using mirrored Vault image repository: ${VAULT_IMAGE_REPOSITORY}"
}

apply_vault_icsp() {
  local vault_enterprise_icsp_source
  local vault_kms_icsp_source
  vault_enterprise_icsp_source="$(resolve_image_repo "${VAULT_ENTERPRISE_IMAGE}")"
  vault_kms_icsp_source="$(resolve_image_repo "${VAULT_KMS_PLUGIN_IMAGE}")"

  echo "Applying ImageContentSourcePolicy for vault images..."
  oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: vault-mirror
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${DS_REGISTRY}/localimages/vault-enterprise
    source: ${vault_enterprise_icsp_source}
  - mirrors:
    - ${DS_REGISTRY}/localimages/vault-kube-kms
    source: ${vault_kms_icsp_source}
EOF

  echo "Waiting for ICSP to propagate to nodes..."
  oc wait machineconfigpool/master --for=condition=Updated=True --timeout=10m
  oc wait machineconfigpool/worker --for=condition=Updated=True --timeout=10m
}

setup_packet_cluster() {
  if [[ -n "${CLUSTER_TYPE:-}" && "${CLUSTER_TYPE}" == equinix-ocp-metal ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/packet-conf.sh"
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/ds-vars.conf"

    # For disconnected or otherwise unreachable environments, we want to
    # have steps use an HTTP(S) proxy to reach the API server. This proxy
    # configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
    # environment variables, as well as their lowercase equivalents (note
    # that libcurl doesn't recognize the uppercase variables).
    if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
      # shellcheck source=/dev/null
      source "${SHARED_DIR}/proxy-conf.sh"
    fi

    # Always mirror on baremetal. Nodes often lack IPv6 egress to quay.io even when
    # DS_IP_STACK=v4 (connected), while pods still use IPv6 addresses. The dev-scripts
    # local registry is reachable from all metal nodes regardless of IP stack.
    echo "mirroring Vault to local registry"
    mirror_vault_images
    apply_vault_icsp
  fi
}

VAULT_HA_REPLICAS="${VAULT_HA_REPLICAS:-3}"
VAULT_INIT_SECRET="vault-init-credentials"
VAULT_INIT_PLACEHOLDER="pending"

# Generate a self-signed CA and server certificate for Vault TLS.
# Args: $1 = namespace, $2 = Helm release name, $3 = replica count
# Sets CA_CERT_TMP to the generated CA certificate path.
generate_vault_tls() {
  local namespace="$1"
  local release_name="$2"
  local replica_count="$3"
  local tls_dir="/tmp/vault-tls-${namespace}"

  rm -rf "${tls_dir}"
  mkdir -p "${tls_dir}"

  echo "Generating Vault TLS CA and server certificate..."
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/CN=Vault KMS CA" \
    -keyout "${tls_dir}/ca.key" -out "${tls_dir}/ca.pem" \
    >/dev/null 2>&1

  openssl req -new -newkey rsa:4096 -nodes \
    -subj "/CN=${release_name}.${namespace}.svc" \
    -keyout "${tls_dir}/tls.key" -out "${tls_dir}/tls.csr" \
    >/dev/null 2>&1

  {
    echo "[req]"
    echo "distinguished_name = req_distinguished_name"
    echo "req_extensions = v3_req"
    echo "[req_distinguished_name]"
    echo "[v3_req]"
    echo "subjectAltName = @alt_names"
    echo "[alt_names]"
    echo "DNS.1 = ${release_name}"
    echo "DNS.2 = ${release_name}.${namespace}.svc"
    echo "DNS.3 = ${release_name}.${namespace}.svc.cluster.local"
    echo "DNS.4 = ${release_name}-internal.${namespace}.svc"
    echo "DNS.5 = ${release_name}-internal.${namespace}.svc.cluster.local"
    echo "DNS.6 = localhost"
    echo "IP.1 = 127.0.0.1"
    local i
    for i in $(seq 0 $((replica_count - 1))); do
      echo "DNS.$((7 + i)) = ${release_name}-${i}.${release_name}-internal"
      echo "DNS.$((7 + replica_count + i)) = ${release_name}-${i}.${release_name}-internal.${namespace}.svc"
      echo "DNS.$((7 + 2 * replica_count + i)) = ${release_name}-${i}.${release_name}-internal.${namespace}.svc.cluster.local"
    done
  } > "${tls_dir}/san.cnf"

  openssl x509 -req -days 3650 \
    -in "${tls_dir}/tls.csr" \
    -CA "${tls_dir}/ca.pem" -CAkey "${tls_dir}/ca.key" -CAcreateserial \
    -out "${tls_dir}/tls.crt" \
    -extensions v3_req -extfile "${tls_dir}/san.cnf" \
    >/dev/null 2>&1

  cp "${tls_dir}/ca.pem" "${tls_dir}/ca.crt"

  oc create secret generic vault-tls \
    --from-file=tls.crt="${tls_dir}/tls.crt" \
    --from-file=tls.key="${tls_dir}/tls.key" \
    --from-file=ca.pem="${tls_dir}/ca.pem" \
    -n "${namespace}" \
    --dry-run=client -o yaml | oc apply -f -

  CA_CERT_TMP="${tls_dir}/ca.pem"
  echo "  ✓ TLS secret vault-tls created in ${namespace}"
}

# Prepare the namespace, SCC, and license secret for a Vault instance.
# Must run before setup_packet_cluster() to avoid proxy interference.
# Args: $1 = namespace, $2 = Helm release name
setup_vault_namespace() {
  local namespace="$1"
  local release_name="$2"

  # Create namespace
  echo "Creating namespace ${namespace}..."
  oc create namespace "${namespace}"

  # Add restricted SCC for Vault service account
  echo "Adding restricted SCC for Vault service account..."
  oc adm policy add-scc-to-user restricted -z "${release_name}" -n "${namespace}"

  # Create Vault license secret from mounted credential
  echo "Creating Vault license secret from mounted credential..."
  oc create secret generic "${VAULT_LICENSE_SECRET_NAME}" \
    --from-file=license=/var/run/vault/tests-private-account/kms-vault-license \
    -n "${namespace}"

  if vault_dev_mode_enabled; then
    return 0
  fi

  # Placeholder init credentials are replaced by etcd-encryption-vault-configure.
  # The unsealer sidecar mounts this secret and waits for the real unseal key.
  echo "Creating placeholder ${VAULT_INIT_SECRET} secret..."
  oc create secret generic "${VAULT_INIT_SECRET}" \
    --from-literal=root-token="${VAULT_INIT_PLACEHOLDER}" \
    --from-literal=unseal-key="${VAULT_INIT_PLACEHOLDER}" \
    -n "${namespace}"
}

# Install a single-replica Vault Enterprise dev instance (bare metal default).
# Args: $1 = namespace, $2 = CA ConfigMap name, $3 = Helm release name
install_vault_dev() {
  local namespace="$1"
  local ca_configmap="$2"
  local release_name="$3"
  local pod_name="${release_name}-0"

  echo ""
  echo "========================================="
  echo "Vault Enterprise Installation via Helm (dev mode)"
  echo "========================================="
  echo "Image: ${VAULT_ENTERPRISE_IMAGE}"
  echo "Namespace: ${namespace}"
  echo ""

  local vault_api_addr="https://${release_name}.${namespace}.svc:8200"
  local values_file="/tmp/vault-values-${namespace}.yaml"
  local vault_server_image="${VAULT_IMAGE_REPOSITORY}:${VAULT_VERSION}"
  if [[ "${VAULT_ENTERPRISE_IMAGE}" == *@* ]]; then
    vault_server_image="${VAULT_IMAGE_REPOSITORY}@${VAULT_VERSION}"
  fi

  echo "Installing Vault Enterprise ${VAULT_ENTERPRISE_IMAGE} in dev mode with TLS..."
  cat > "${values_file}" <<EOF
global:
  enabled: true
  openshift: true
  tlsDisable: false

injector:
  enabled: false

server:
  image:
    repository: ${VAULT_IMAGE_REPOSITORY}
    tag: ${VAULT_VERSION}
  dev:
    enabled: true
  extraArgs: >-
    -dev-tls
    -dev-tls-cert-dir=/var/run/tls
    -dev-tls-san=${release_name}
    -dev-tls-san=${release_name}.${namespace}.svc
  extraEnvironmentVars:
    VAULT_DISABLE_USER_LOCKOUT: "true"
    VAULT_CACERT: /var/run/tls/vault-ca.pem
    VAULT_API_ADDR: ${vault_api_addr}
  enterpriseLicense:
    secretName: ${VAULT_LICENSE_SECRET_NAME}
    secretKey: license
  volumes:
    - name: tls
      emptyDir: {}
  volumeMounts:
    - name: tls
      mountPath: /var/run/tls
EOF

  helm upgrade --install "${release_name}" "${VAULT_CHART_ARCHIVE}" \
    --namespace "${namespace}" \
    --version "${VAULT_CHART_VERSION}" \
    -f "${values_file}" \
    --wait \
    --timeout 10m

  if [[ "${VAULT_ENTERPRISE_IMAGE}" == *@* ]]; then
    echo "Patching Vault StatefulSet image to digest reference ${vault_server_image}..."
    oc set image "statefulset/${release_name}" \
      vault="${vault_server_image}" \
      -n "${namespace}"
    oc rollout status "statefulset/${release_name}" -n "${namespace}" --timeout=10m
  fi

  echo "Waiting for Vault pod to be ready..."
  oc wait --for=condition=ready "pod/${pod_name}" -n "${namespace}" --timeout=5m

  echo ""
  echo "Extracting CA certificate from Vault pod..."
  CA_CERT_TMP="/tmp/vault-ca-${namespace}.pem"
  oc exec "${pod_name}" -n "${namespace}" -- cat /var/run/tls/vault-ca.pem > "${CA_CERT_TMP}"
  echo "  ✓ CA certificate extracted"

  echo ""
  echo "Creating ConfigMap ${ca_configmap} in openshift-config..."
  oc create configmap "${ca_configmap}" \
    --from-file=ca-bundle.crt="${CA_CERT_TMP}" \
    -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -
  echo "  ✓ ConfigMap ${ca_configmap} created/updated"

  rm -f "${CA_CERT_TMP}" "${values_file}"

  echo ""
  echo "========================================="
  echo "Vault Enterprise Installation Complete (dev mode)"
  echo "========================================="
  echo ""
  echo "Summary:"
  echo "  - Namespace: ${namespace}"
  echo "  - Image: ${VAULT_ENTERPRISE_IMAGE}"
  echo "  - Service: https://${release_name}.${namespace}.svc:8200"
  echo "  - Pod: ${pod_name} (Ready)"
  echo "  - Mode: dev (pre-initialized, root token \"root\")"
  echo "  - TLS: Enabled (dev mode with auto-generated certificates)"
  echo "  - TLS CA: /var/run/tls/vault-ca.pem (inside pod)"
  echo "  - Enterprise License: Configured"
  echo "  - CA ConfigMap: ${ca_configmap} (openshift-config namespace)"
  echo ""
  echo "Next step: Run etcd-encryption-vault-configure to configure Vault for KMS"
  echo ""
}

# Install a Vault Enterprise HA Raft cluster.
# Args: $1 = namespace, $2 = CA ConfigMap name, $3 = Helm release name
install_vault_ha() {
  local namespace="$1"
  local ca_configmap="$2"
  local release_name="$3"

  echo ""
  echo "========================================="
  echo "Vault Enterprise Installation via Helm (HA Raft)"
  echo "========================================="
  echo "Image: ${VAULT_ENTERPRISE_IMAGE}"
  echo "Namespace: ${namespace}"
  echo ""

  local vault_api_addr="https://${release_name}.${namespace}.svc:8200"
  local values_file="/tmp/vault-values-${namespace}.yaml"
  local vault_server_image="${VAULT_IMAGE_REPOSITORY}:${VAULT_VERSION}"
  if [[ "${VAULT_ENTERPRISE_IMAGE}" == *@* ]]; then
    vault_server_image="${VAULT_IMAGE_REPOSITORY}@${VAULT_VERSION}"
  fi

  generate_vault_tls "${namespace}" "${release_name}" "${VAULT_HA_REPLICAS}"

  # Install Vault via Helm in HA Raft mode with TLS and persistent storage.
  echo "Installing Vault Enterprise ${VAULT_ENTERPRISE_IMAGE} in HA Raft mode with TLS..."
  cat > "${values_file}" <<EOF
global:
  enabled: true
  openshift: true
  tlsDisable: false

injector:
  enabled: false

server:
  image:
    repository: ${VAULT_IMAGE_REPOSITORY}
    tag: ${VAULT_VERSION}
  dev:
    enabled: false
  standalone:
    enabled: false
  ha:
    enabled: true
    replicas: ${VAULT_HA_REPLICAS}
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true

        listener "tcp" {
          tls_disable = 0
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_cert_file = "/vault/userconfig/vault-tls/tls.crt"
          tls_key_file = "/vault/userconfig/vault-tls/tls.key"
          tls_client_ca_file = "/vault/userconfig/vault-tls/ca.pem"
        }

        storage "raft" {
          path = "/vault/data"
          retry_join {
            leader_api_addr = "https://${release_name}.${namespace}.svc:8200"
            leader_tls_servername = "${release_name}.${namespace}.svc"
            leader_ca_cert_file = "/vault/userconfig/vault-tls/ca.pem"
            leader_client_cert_file = "/vault/userconfig/vault-tls/tls.crt"
            leader_client_key_file = "/vault/userconfig/vault-tls/tls.key"
          }
        }

        service_registration "kubernetes" {}
  dataStorage:
    enabled: true
  tolerations:
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  readinessProbe:
    enabled: true
    path: "/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200"
  enterpriseLicense:
    secretName: ${VAULT_LICENSE_SECRET_NAME}
    secretKey: license
  extraEnvironmentVars:
    VAULT_DISABLE_USER_LOCKOUT: "true"
    VAULT_CACERT: /vault/userconfig/vault-tls/ca.pem
    VAULT_API_ADDR: ${vault_api_addr}
  extraVolumes:
    - type: secret
      name: vault-tls
    - type: secret
      name: ${VAULT_INIT_SECRET}
  extraContainers:
    - name: vault-unsealer
      image: ${vault_server_image}
      command:
        - /bin/sh
        - -c
      args:
        - |
          set -u
          export VAULT_ADDR=https://127.0.0.1:8200
          export VAULT_CACERT=/vault/userconfig/vault-tls/ca.pem
          UNSEAL_KEY_FILE=/vault/userconfig/${VAULT_INIT_SECRET}/unseal-key
          PLACEHOLDER=${VAULT_INIT_PLACEHOLDER}
          log() {
            echo "\$(date -u +%Y-%m-%dT%H:%M:%SZ) vault-unsealer: \$*"
          }
          log "starting"
          while true; do
            if [ ! -f "\${UNSEAL_KEY_FILE}" ]; then
              log "waiting for \${UNSEAL_KEY_FILE}"
              sleep 10
              continue
            fi
            UNSEAL_KEY=\$(tr -d '\\n' < "\${UNSEAL_KEY_FILE}")
            if [ -z "\${UNSEAL_KEY}" ] || [ "\${UNSEAL_KEY}" = "\${PLACEHOLDER}" ]; then
              log "waiting for real unseal key (placeholder or empty)"
              sleep 10
              continue
            fi
            STATUS_JSON=\$(vault status -format=json 2>/dev/null || true)
            if [ -z "\${STATUS_JSON}" ]; then
              log "vault status unavailable, retrying"
              sleep 10
              continue
            fi
            if echo "\${STATUS_JSON}" | tr -d ' \n' | grep -q '"sealed":true'; then
              log "vault is sealed, attempting unseal"
              if vault operator unseal "\${UNSEAL_KEY}"; then
                log "unseal command succeeded"
              else
                log "unseal command failed"
              fi
            else
              log "vault is already unsealed"
            fi
            sleep 30
          done
      volumeMounts:
        - name: userconfig-vault-tls
          mountPath: /vault/userconfig/vault-tls
          readOnly: true
        - name: userconfig-${VAULT_INIT_SECRET}
          mountPath: /vault/userconfig/${VAULT_INIT_SECRET}
          readOnly: true
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
EOF

  helm upgrade --install "${release_name}" "${VAULT_CHART_ARCHIVE}" \
    --namespace "${namespace}" \
    --version "${VAULT_CHART_VERSION}" \
    -f "${values_file}" \
    --wait \
    --timeout 15m

  # Vault Helm 0.28.1 renders server images as repository:tag, which breaks digest pins.
  if [[ "${VAULT_ENTERPRISE_IMAGE}" == *@* ]]; then
    echo "Patching Vault StatefulSet images to digest reference ${vault_server_image}..."
    oc set image "statefulset/${release_name}" \
      vault="${vault_server_image}" \
      vault-unsealer="${vault_server_image}" \
      -n "${namespace}"
    oc rollout status "statefulset/${release_name}" -n "${namespace}" --timeout=15m
  fi

  # Helm wait passes even when vault pods are 0/1 Running, so wait for ready condition.
  echo "Waiting for Vault pods to be ready..."
  local i
  for i in $(seq 0 $((VAULT_HA_REPLICAS - 1))); do
    oc wait --for=condition=ready "pod/${release_name}-${i}" -n "${namespace}" --timeout=10m
  done

  # Create or update ConfigMap with CA certificate in openshift-config
  echo ""
  echo "Creating ConfigMap ${ca_configmap} in openshift-config..."
  oc create configmap "${ca_configmap}" \
    --from-file=ca-bundle.crt="${CA_CERT_TMP}" \
    -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -
  echo "  ✓ ConfigMap ${ca_configmap} created/updated"

  # Clean up temporary TLS artifacts
  rm -rf "/tmp/vault-tls-${namespace}" "${values_file}"

  echo ""
  echo "========================================="
  echo "Vault Enterprise Installation Complete"
  echo "========================================="
  echo ""
  echo "Summary:"
  echo "  - Namespace: ${namespace}"
  echo "  - Image: ${VAULT_ENTERPRISE_IMAGE}"
  echo "  - Service: https://${release_name}.${namespace}.svc:8200"
  echo "  - HA Replicas: ${VAULT_HA_REPLICAS} (${release_name}-0..${release_name}-$((VAULT_HA_REPLICAS - 1)))"
  echo "  - Control-plane tolerations: enabled"
  echo "  - Storage: Raft integrated storage with PVC persistence"
  echo "  - TLS: Enabled (self-signed CA in vault-tls secret)"
  echo "  - TLS CA: /vault/userconfig/vault-tls/ca.pem (inside pod)"
  echo "  - Unsealer: vault-unsealer sidecar (auto-unseals after pod restarts)"
  echo "  - Enterprise License: Configured"
  echo "  - CA ConfigMap: ${ca_configmap} (openshift-config namespace)"
  echo ""
  echo "Next step: Run etcd-encryption-vault-configure to initialize and configure Vault for KMS"
  echo ""
}

# Install a Vault Enterprise instance in the given namespace.
# Args: $1 = namespace, $2 = CA ConfigMap name, $3 = Helm release name
install_vault() {
  if vault_dev_mode_enabled; then
    install_vault_dev "$@"
  else
    install_vault_ha "$@"
  fi
}

# Vault license secret name
VAULT_LICENSE_SECRET_NAME="vault-license"

# Install Helm if not present
if ! command -v helm &> /dev/null; then
  echo "Installing Helm..."
  HELM_VERSION="3.14.0"
  curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  mkdir -p /tmp/bin
  mv /tmp/linux-amd64/helm /tmp/bin/helm
  chmod +x /tmp/bin/helm
  export PATH="/tmp/bin:$PATH"
  rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
  echo "Helm installed: $(helm version --short)"
else
  echo "Helm already installed: $(helm version --short)"
fi

echo ""

record_vault_images

if vault_dev_mode_enabled; then
  echo "Vault install mode: dev (bare metal default)"
  echo "true" > "${SHARED_DIR}/vault-dev-mode"
else
  echo "Vault install mode: HA Raft"
  echo "false" > "${SHARED_DIR}/vault-dev-mode"
fi

setup_vault_namespace "${VAULT_NAMESPACE}" "vault"
setup_vault_namespace "${VAULT_SECONDARY_NAMESPACE}" "vault-secondary"

# Fetch the Helm chart before baremetalds proxy env is applied; hashicorp chart
# downloads fail with Forbidden once proxy-conf.sh is sourced on metal jobs.
echo "Fetching HashiCorp Vault Helm chart..."
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
VAULT_CHART_ARCHIVE="/tmp/vault-${VAULT_CHART_VERSION}.tgz"
helm pull hashicorp/vault --version "${VAULT_CHART_VERSION}" --destination /tmp
echo "Chart downloaded to ${VAULT_CHART_ARCHIVE}"

echo ""

setup_packet_cluster

install_vault "${VAULT_NAMESPACE}" "vault-ca-bundle" "vault"
install_vault "${VAULT_SECONDARY_NAMESPACE}" "vault-ca-bundle-secondary" "vault-secondary"
