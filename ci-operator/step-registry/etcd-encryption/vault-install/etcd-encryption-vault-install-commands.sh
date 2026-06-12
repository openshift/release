#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

mirror_vault_image() {
  echo "Mirroring Vault image to dev-scripts local registry..."

  VAULT_IMAGE="${VAULT_IMAGE_REPOSITORY}:${VAULT_VERSION}"
  DEVSCRIPTS_VAULT_IMAGE="${DS_REGISTRY}/localimages/vault-enterprise:${VAULT_VERSION}"

  echo "  Source: ${VAULT_IMAGE}"
  echo "  Destination: ${DEVSCRIPTS_VAULT_IMAGE}"

  # shellcheck disable=SC2087
  ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -euo pipefail
oc image mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json "${VAULT_IMAGE}" "${DEVSCRIPTS_VAULT_IMAGE}"
EOF

  VAULT_IMAGE_REPOSITORY="${DS_REGISTRY}/localimages/vault-enterprise"
  echo "Using mirrored Vault image repository: ${VAULT_IMAGE_REPOSITORY}"
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
    mirror_vault_image
  fi
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
}

# Install a Vault Enterprise instance in the given namespace.
# Args: $1 = namespace, $2 = CA ConfigMap name, $3 = Helm release name
install_vault() {
  local namespace="$1"
  local ca_configmap="$2"
  local release_name="$3"
  local pod_name="${release_name}-0"

  echo ""
  echo "========================================="
  echo "Vault Enterprise Installation via Helm"
  echo "========================================="
  echo "Version: ${VAULT_VERSION}"
  echo "Namespace: ${namespace}"
  echo ""

  local vault_api_addr="https://${release_name}.${namespace}.svc:8200"

  # Install Vault via Helm with dev mode and TLS enabled
  echo "Installing Vault Enterprise v${VAULT_VERSION} in dev mode with TLS..."
  helm upgrade --install "${release_name}" "${VAULT_CHART_ARCHIVE}" \
    --namespace "${namespace}" \
    --version "${VAULT_CHART_VERSION}" \
    --set global.enabled=true \
    --set global.openshift=true \
    --set global.tlsDisable=false \
    --set server.dev.enabled=true \
    --set server.image.repository="${VAULT_IMAGE_REPOSITORY}" \
    --set server.image.tag="${VAULT_VERSION}" \
    --set injector.enabled=false \
    --set 'server.extraEnvironmentVars.VAULT_DISABLE_USER_LOCKOUT=true' \
    --set 'server.extraEnvironmentVars.VAULT_CACERT=/var/run/tls/vault-ca.pem' \
    --set "server.extraEnvironmentVars.VAULT_API_ADDR=${vault_api_addr}" \
    --set "server.enterpriseLicense.secretName=${VAULT_LICENSE_SECRET_NAME}" \
    --set "server.enterpriseLicense.secretKey=license" \
    --set "server.extraArgs=-dev-tls -dev-tls-cert-dir=/var/run/tls -dev-tls-san=${release_name} -dev-tls-san=${release_name}.${namespace}.svc" \
    --set 'server.volumes[0].name=tls' \
    --set-json 'server.volumes[0].emptyDir={}' \
    --set 'server.volumeMounts[0].name=tls' \
    --set 'server.volumeMounts[0].mountPath=/var/run/tls' \
    --wait \
    --timeout 10m

  # Helm wait passes even when vault pod is 0/1 Running, so wait for ready condition
  echo "Waiting for Vault pod to be ready..."
  oc wait --for=condition=ready "pod/${pod_name}" -n "${namespace}" --timeout=5m

  # Extract CA certificate from Vault pod
  echo ""
  echo "Extracting CA certificate from Vault pod..."
  CA_CERT_TMP="/tmp/vault-ca-${namespace}.pem"
  oc exec "${pod_name}" -n "${namespace}" -- cat /var/run/tls/vault-ca.pem > "${CA_CERT_TMP}"
  echo "  ✓ CA certificate extracted"

  # Create or update ConfigMap with CA certificate in openshift-config
  echo ""
  echo "Creating ConfigMap ${ca_configmap} in openshift-config..."
  oc create configmap "${ca_configmap}" \
    --from-file=ca-bundle.crt="${CA_CERT_TMP}" \
    -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -
  echo "  ✓ ConfigMap ${ca_configmap} created/updated"

  # Clean up temporary CA file
  rm -f "${CA_CERT_TMP}"

  echo ""
  echo "========================================="
  echo "Vault Enterprise Installation Complete"
  echo "========================================="
  echo ""
  echo "Summary:"
  echo "  - Namespace: ${namespace}"
  echo "  - Version: ${VAULT_VERSION}"
  echo "  - Service: https://${release_name}.${namespace}.svc:8200"
  echo "  - Pod: ${pod_name} (Ready)"
  echo "  - TLS: Enabled (dev mode with auto-generated certificates)"
  echo "  - TLS CA: /var/run/tls/vault-ca.pem (inside pod)"
  echo "  - Enterprise License: Configured"
  echo "  - CA ConfigMap: ${ca_configmap} (openshift-config namespace)"
  echo ""
  echo "Next step: Run etcd-encryption-vault-configure to configure Vault for KMS"
  echo ""
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
