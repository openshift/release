#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

VAULT_LICENSE_SECRET_NAME="vault-license"

install_helm() {
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

  echo "Adding HashiCorp Helm repository..."
  helm repo add hashicorp https://helm.releases.hashicorp.com
  helm repo update
}

# Install a Vault Enterprise instance in the given namespace.
# Args: $1 = namespace, $2 = CA ConfigMap name, $3 = Helm release name
install_vault() {
  local ns="$1"
  local ca_configmap="$2"
  local release_name="$3"
  local pod_name="${release_name}-0"

  echo ""
  echo "========================================="
  echo "Vault Enterprise Installation via Helm"
  echo "========================================="
  echo "Version: ${VAULT_VERSION}"
  echo "Namespace: ${ns}"
  echo ""

  echo "Creating namespace ${ns}..."
  oc create namespace "${ns}"

  echo "Adding restricted SCC for Vault service account..."
  oc adm policy add-scc-to-user restricted -z vault -n "${ns}"

  echo "Creating Vault license secret from mounted credential..."
  oc create secret generic "${VAULT_LICENSE_SECRET_NAME}" \
    --from-file=license=/var/run/vault/tests-private-account/kms-vault-license \
    -n "${ns}"

  echo ""
  echo "Installing Vault Enterprise v${VAULT_VERSION} in dev mode with TLS..."
  helm upgrade --install "${release_name}" hashicorp/vault \
    --namespace "${ns}" \
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
    --set "server.enterpriseLicense.secretName=${VAULT_LICENSE_SECRET_NAME}" \
    --set "server.enterpriseLicense.secretKey=license" \
    --set "server.extraArgs=-dev-tls -dev-tls-cert-dir=/var/run/tls -dev-tls-san=vault -dev-tls-san=vault.${ns}.svc" \
    --set 'server.volumes[0].name=tls' \
    --set-json 'server.volumes[0].emptyDir={}' \
    --set 'server.volumeMounts[0].name=tls' \
    --set 'server.volumeMounts[0].mountPath=/var/run/tls' \
    --wait \
    --timeout 10m

  # Helm wait passes even when vault pod is 0/1 Running, so wait for ready condition
  echo "Waiting for Vault pod to be ready..."
  oc wait --for=condition=ready "pod/${pod_name}" -n "${ns}" --timeout=5m

  # Extract CA certificate from Vault pod
  echo ""
  echo "Extracting CA certificate from Vault pod..."
  local ca_cert_tmp="/tmp/vault-ca-${ns}.pem"
  oc exec "${pod_name}" -n "${ns}" -- cat /var/run/tls/vault-ca.pem > "${ca_cert_tmp}"
  echo "  ✓ CA certificate extracted"

  # Create or update ConfigMap with CA certificate in openshift-config
  echo ""
  echo "Creating ConfigMap ${ca_configmap} in openshift-config..."
  oc create configmap "${ca_configmap}" \
    --from-file=ca-bundle.crt="${ca_cert_tmp}" \
    -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -
  echo "  ✓ ConfigMap ${ca_configmap} created/updated"

  # Clean up temporary CA file
  rm -f "${ca_cert_tmp}"

  echo ""
  echo "========================================="
  echo "Vault Enterprise Installation Complete"
  echo "========================================="
  echo ""
  echo "Summary:"
  echo "  - Namespace: ${ns}"
  echo "  - Version: ${VAULT_VERSION}"
  echo "  - Service: https://vault.${ns}.svc:8200"
  echo "  - Pod: vault-0 (Ready)"
  echo "  - TLS: Enabled (dev mode with auto-generated certificates)"
  echo "  - TLS CA: /var/run/tls/vault-ca.pem (inside pod)"
  echo "  - Enterprise License: Configured"
  echo "  - CA ConfigMap: ${ca_configmap} (openshift-config namespace)"
  echo ""
  echo "Next step: Run etcd-encryption-vault-configure to configure Vault for KMS"
  echo ""
}

install_helm

install_vault "${VAULT_NAMESPACE}" "vault-ca-bundle" "vault"
install_vault "${VAULT_SECONDARY_NAMESPACE}" "vault-ca-bundle-2" "vault-2"
