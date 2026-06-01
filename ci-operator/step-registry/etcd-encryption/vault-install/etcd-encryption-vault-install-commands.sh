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

# Create a passthrough Route first so we can include its hostname in the TLS SANs.
# kube-apiserver uses hostNetwork:true, so it cannot resolve cluster-internal DNS
# (vault.vault-kms.svc). A Route gives us an externally resolvable address.
echo "Creating passthrough Route for Vault..."
cat <<ROUTE_EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: vault
  namespace: ${VAULT_NAMESPACE}
spec:
  port:
    targetPort: 8200
  tls:
    termination: passthrough
  to:
    kind: Service
    name: vault
    weight: 100
ROUTE_EOF

VAULT_ROUTE_HOST=$(oc get route vault -n "${VAULT_NAMESPACE}" -o jsonpath='{.spec.host}')
if [[ -z "${VAULT_ROUTE_HOST}" ]]; then
  echo "ERROR: Failed to get route hostname"
  exit 1
fi
echo "  Route hostname: ${VAULT_ROUTE_HOST}"

# Install Vault via Helm with dev mode and TLS enabled
echo "Installing Vault Enterprise v${VAULT_VERSION} in dev mode with TLS..."
helm upgrade --install vault hashicorp/vault \
  --namespace "${VAULT_NAMESPACE}" \
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
  --set "server.extraArgs=-dev-tls -dev-tls-cert-dir=/var/run/tls -dev-tls-san=vault -dev-tls-san=vault.${VAULT_NAMESPACE}.svc -dev-tls-san=${VAULT_ROUTE_HOST}" \
  --set 'server.volumes[0].name=tls' \
  --set-json 'server.volumes[0].emptyDir={}' \
  --set 'server.volumeMounts[0].name=tls' \
  --set 'server.volumeMounts[0].mountPath=/var/run/tls' \
  --wait \
  --timeout 10m

# Helm wait passes even when vault pod is 0/1 Running, so wait for ready condition
echo "Waiting for Vault pod to be ready..."
oc wait --for=condition=ready pod/vault-0 -n "${VAULT_NAMESPACE}" --timeout=5m

# Extract CA certificate from Vault pod
echo ""
echo "Extracting CA certificate from Vault pod..."
CA_CERT_TMP="/tmp/vault-ca-${VAULT_NAMESPACE}.pem"
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- cat /var/run/tls/vault-ca.pem > "${CA_CERT_TMP}"
echo "  ✓ CA certificate extracted"

# Create or update ConfigMap with CA certificate in openshift-config
echo ""
echo "Creating ConfigMap vault-ca-bundle in openshift-config..."
oc create configmap vault-ca-bundle \
  --from-file=ca-bundle.crt="${CA_CERT_TMP}" \
  -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -
echo "  ✓ ConfigMap vault-ca-bundle created/updated"

# Clean up temporary CA file
rm -f "${CA_CERT_TMP}"

# Store route host in SHARED_DIR for subsequent steps and tests
echo "${VAULT_ROUTE_HOST}" > "${SHARED_DIR}/vault-route-host"
echo "Route host saved to SHARED_DIR/vault-route-host"

echo ""
echo "========================================="
echo "Vault Enterprise Installation Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Namespace: ${VAULT_NAMESPACE}"
echo "  - Version: ${VAULT_VERSION}"
echo "  - Internal Service: https://vault.${VAULT_NAMESPACE}.svc:8200"
echo "  - External Route: https://${VAULT_ROUTE_HOST}"
echo "  - Pod: vault-0 (Ready)"
echo "  - TLS: Enabled (dev mode with auto-generated certificates)"
echo "  - TLS SANs: vault, vault.${VAULT_NAMESPACE}.svc, ${VAULT_ROUTE_HOST}"
echo "  - TLS CA: /var/run/tls/vault-ca.pem (inside pod)"
echo "  - Enterprise License: Configured"
echo "  - CA ConfigMap: vault-ca-bundle (openshift-config namespace)"
echo ""
echo "Note: kube-apiserver uses hostNetwork:true and cannot resolve internal DNS."
echo "Use the Route address (https://${VAULT_ROUTE_HOST}) for KMS plugin config."
echo ""
echo "Next step: Run etcd-encryption-vault-configure to configure Vault for KMS"
echo ""
