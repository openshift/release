#!/bin/bash
set -euo pipefail

echo "========================================="
echo "Vault Enterprise Installation via Helm"
echo "========================================="
echo "Version: ${VAULT_VERSION}"
echo "Namespace: ${VAULT_NAMESPACE}"
echo ""

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

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

# Create namespace
echo "Creating namespace ${VAULT_NAMESPACE}..."
oc create namespace "${VAULT_NAMESPACE}"

# Add restricted SCC for Vault service account
echo "Adding restricted SCC for Vault service account..."
oc adm policy add-scc-to-user restricted -z vault -n "${VAULT_NAMESPACE}"

# Create Vault license secret from mounted credential
echo "Creating Vault license secret from mounted credential..."
oc create secret generic "${VAULT_LICENSE_SECRET_NAME}" \
  --from-file=license=/var/run/vault/tests-private-account/kms-vault-license \
  -n "${VAULT_NAMESPACE}"

# Add HashiCorp Helm repository
echo "Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

echo ""

# Install Vault via Helm with dev mode enabled
echo "Installing Vault Enterprise v${VAULT_VERSION} in dev mode..."
helm upgrade --install vault hashicorp/vault \
  --namespace "${VAULT_NAMESPACE}" \
  --version "${VAULT_CHART_VERSION}" \
  --set global.enabled=true \
  --set global.openshift=true \
  --set server.dev.enabled=true \
  --set server.image.repository="${VAULT_IMAGE_REPOSITORY}" \
  --set server.image.tag="${VAULT_VERSION}" \
  --set injector.enabled=false \
  --set 'server.extraEnvironmentVars.VAULT_DISABLE_USER_LOCKOUT=true' \
  --set "server.enterpriseLicense.secretName=${VAULT_LICENSE_SECRET_NAME}" \
  --set "server.enterpriseLicense.secretKey=license" \
  --wait \
  --timeout 10m

#helm wait passes even vault pod is 0/1 Running. So, added the below wait to correctly verify the vault pod status
echo "Waiting for Vault pod to be ready..."  
oc wait --for=condition=ready pod/vault-0 -n "${VAULT_NAMESPACE}" --timeout=5m

echo "========================================="
echo "Vault Enterprise Installation Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Namespace: ${VAULT_NAMESPACE}"
echo "  - Version: ${VAULT_VERSION}"
echo "  - Service: vault.${VAULT_NAMESPACE}.svc:8200"
echo "  - Pod: vault-0 (Ready)"
echo ""
echo "Next step: Run etcd-encryption-vault-configure to configure Vault for KMS"
echo ""
