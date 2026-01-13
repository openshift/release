#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========== Dependency Installation =========="

# Install yq if not available
if ! command -v yq &> /dev/null; then
    echo "yq not found, installing..."
    curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /tmp/yq
    chmod +x /tmp/yq
    export PATH="/tmp:${PATH}"
    echo "yq installed successfully"
else
    echo "yq is already installed"
fi

# Install kubectl if not available
if ! command -v kubectl &> /dev/null; then
    echo "kubectl not found, installing..."
    # Use a fixed stable version to avoid issues with version lookup
    KUBECTL_VERSION="v1.31.0"
    curl -sL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
    chmod +x /tmp/kubectl
    export PATH="/tmp:${PATH}"
    echo "kubectl ${KUBECTL_VERSION} installed successfully"
else
    echo "kubectl is already installed"
fi

# Install helm if not available
if ! command -v helm &> /dev/null; then
    echo "helm not found, installing..."
    curl -sL https://get.helm.sh/helm-v3.13.0-linux-amd64.tar.gz -o /tmp/helm.tar.gz
    tar -xzf /tmp/helm.tar.gz -C /tmp
    mv /tmp/linux-amd64/helm /tmp/helm
    chmod +x /tmp/helm
    export PATH="/tmp:${PATH}"
    echo "helm installed successfully"
else
    echo "helm is already installed"
fi

# Install oc if not available
if ! command -v oc &> /dev/null; then
    echo "oc not found, installing..."
    curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz -o /tmp/oc.tar.gz
    tar -xzf /tmp/oc.tar.gz -C /tmp oc
    chmod +x /tmp/oc
    export PATH="/tmp:${PATH}"
    echo "oc installed successfully"
else
    echo "oc is already installed"
fi

echo "========== MinIO Configuration =========="

# Read MinIO configuration from SHARED_DIR (set by insights-onprem-minio-deploy step)
if [ -f "${SHARED_DIR}/minio-env" ]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/minio-env"
    
    # Export the variables we need
    export MINIO_HOST
    export MINIO_PORT
    export MINIO_ENDPOINT
    export MINIO_NAMESPACE
    export APP_NAMESPACE
    
    echo "MinIO host: ${MINIO_HOST}"
    echo "MinIO port: ${MINIO_PORT}"
    echo "MinIO endpoint (host:port): ${MINIO_ENDPOINT}"
    echo "MinIO namespace: ${MINIO_NAMESPACE}"
    echo "Application namespace: ${APP_NAMESPACE}"
    
    # Set NAMESPACE for the helm chart deployment
    if [ -n "${APP_NAMESPACE:-}" ]; then
        export NAMESPACE="${APP_NAMESPACE}"
    fi
else
    echo "WARNING: MinIO configuration not found in SHARED_DIR"
    echo "Make sure insights-onprem-minio-deploy step ran before this step"
fi

# Read credentials from separate files
if [ -f "${SHARED_DIR}/minio-access-key" ]; then
    MINIO_ACCESS_KEY=$(cat "${SHARED_DIR}/minio-access-key")
    export MINIO_ACCESS_KEY
    MINIO_SECRET_KEY=$(cat "${SHARED_DIR}/minio-secret-key")
    export MINIO_SECRET_KEY
fi

echo "========== Installing Cost Management Operator =========="
# Pre-install the Cost Management Operator without startingCSV
# This ensures the operator is installed with whatever version is available in the catalog
# The upstream setup-cost-mgmt-tls.sh will skip installation if it's already present

# Check if we should skip operator installation
if [ "${SKIP_COST_MGMT_INSTALL:-false}" == "true" ]; then
    echo "SKIP_COST_MGMT_INSTALL=true, skipping Cost Management Operator installation"
else

# Use the application namespace (defaults to cost-onprem)
COST_MGMT_NAMESPACE="${NAMESPACE:-cost-onprem}"
echo "Installing Cost Management Operator in namespace: ${COST_MGMT_NAMESPACE}"
echo "Channel: ${COST_MGMT_CHANNEL:-stable}, Source: ${COST_MGMT_SOURCE:-redhat-operators}"

# List available versions of the Cost Management Operator
echo "Checking available versions of costmanagement-metrics-operator in catalog..."
if oc get packagemanifest costmanagement-metrics-operator -n openshift-marketplace &> /dev/null; then
    echo "Package manifest found. Available channels and versions:"
    oc get packagemanifest costmanagement-metrics-operator -n openshift-marketplace -o jsonpath='{range .status.channels[*]}Channel: {.name}, Current CSV: {.currentCSV}{"\n"}{end}' || true
    echo ""
    echo "Default channel: $(oc get packagemanifest costmanagement-metrics-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')" || true
else
    echo "WARNING: costmanagement-metrics-operator package manifest not found in catalog"
fi

# Check if operator is already installed
if oc get subscription costmanagement-metrics-operator -n "${COST_MGMT_NAMESPACE}" &> /dev/null; then
    echo "Cost Management Operator already installed, skipping..."
else
    echo "Ensuring namespace ${COST_MGMT_NAMESPACE} exists..."
    oc create namespace "${COST_MGMT_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

    echo "Creating OperatorGroup..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: costmanagement-metrics-operator
  namespace: ${COST_MGMT_NAMESPACE}
spec:
  targetNamespaces:
  - ${COST_MGMT_NAMESPACE}
EOF

    echo "Creating Subscription (without startingCSV to use latest available version)..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: costmanagement-metrics-operator
  namespace: ${COST_MGMT_NAMESPACE}
spec:
  channel: ${COST_MGMT_CHANNEL:-stable}
  name: costmanagement-metrics-operator
  source: ${COST_MGMT_SOURCE:-redhat-operators}
  sourceNamespace: openshift-marketplace
EOF

    echo "Waiting for Cost Management Operator to be ready..."
    # Wait for the CSV to be installed
    TIMEOUT="${OPERATOR_INSTALL_TIMEOUT:-300}"
    ELAPSED=0
    while [ $ELAPSED -lt "$TIMEOUT" ]; do
        if oc get csv -n "${COST_MGMT_NAMESPACE}" 2>/dev/null | grep -q "costmanagement-metrics-operator.*Succeeded"; then
            echo "Cost Management Operator installed successfully"
            break
        fi
        echo "Waiting for operator CSV to succeed... (${ELAPSED}s elapsed)"
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done

    if [ $ELAPSED -ge "$TIMEOUT" ]; then
        echo "WARNING: Timeout waiting for Cost Management Operator, continuing anyway..."
        oc get csv -n "${COST_MGMT_NAMESPACE}" || true
        oc get subscription -n "${COST_MGMT_NAMESPACE}" -o yaml || true
    fi
fi

fi  # end SKIP_COST_MGMT_INSTALL check

echo "========== Configuring Helm for MinIO Storage =========="
# Tell the Helm chart to use MinIO instead of ODF (NooBaa)
# This prevents the chart from trying to lookup NooBaa CRDs which don't exist
# when using MinIO for object storage

# IMPORTANT: Find the REAL helm binary location BEFORE we create any wrappers
# If helm was installed to /tmp/helm, we need to find the actual binary
ORIGINAL_HELM=$(command -v helm)
if [[ "${ORIGINAL_HELM}" == "/tmp/helm" ]]; then
    # Helm was installed to /tmp, use the actual binary path
    # Move it to a different location to avoid conflicts with the wrapper
    mv /tmp/helm /tmp/helm-original
    ORIGINAL_HELM="/tmp/helm-original"
    echo "Moved original helm to ${ORIGINAL_HELM}"
fi

HELM_WRAPPER="/tmp/helm-wrapper"

cat > "${HELM_WRAPPER}" << 'WRAPPER_EOF'
#!/bin/bash
# Helm wrapper that injects MinIO storage configuration
# This intercepts helm calls and adds MinIO config
# ONLY for the cost-onprem chart - other charts pass through unchanged

ORIGINAL_HELM="__ORIGINAL_HELM__"

# Only inject MinIO config for the cost-onprem chart installation
# Check if this is an install/upgrade command for cost-onprem specifically
if [[ "$*" == *"cost-onprem"* ]] && { [[ "$*" == *"upgrade"* ]] || [[ "$*" == *"install"* ]]; }; then
    echo "[helm-wrapper] Detected cost-onprem chart - injecting MinIO storage configuration..."
    # IMPORTANT: Do NOT set global.storageType=minio as that breaks OpenShift security contexts
    # Instead, set odf.endpoint explicitly - the chart should skip NooBaa lookup when endpoint is provided
    # We use a proxy service (minio-storage) in the app namespace that routes to MinIO.
    echo "[helm-wrapper] Using MinIO host: ${MINIO_HOST:-minio-storage}, port: ${MINIO_PORT:-9000}"
    exec "$ORIGINAL_HELM" "$@" \
        --set "odf.endpoint=${MINIO_HOST:-minio-storage}" \
        --set "odf.port=${MINIO_PORT:-9000}" \
        --set "odf.useSSL=false" \
        --set "odf.bucket=${MINIO_BUCKET:-ros-data}" \
        --set "odf.skipLookup=true"
else
    # For all other helm commands (repo add, strimzi install, etc.), pass through unchanged
    exec "$ORIGINAL_HELM" "$@"
fi
WRAPPER_EOF

# Replace placeholders with actual values
sed -i "s|__ORIGINAL_HELM__|${ORIGINAL_HELM}|g" "${HELM_WRAPPER}"

chmod +x "${HELM_WRAPPER}"

# Create symlink so 'helm' resolves to our wrapper
ln -sf "${HELM_WRAPPER}" /tmp/helm

echo "Helm wrapper installed at /tmp/helm"
echo "Original helm binary: ${ORIGINAL_HELM}"
echo "MinIO storage type will be injected for cost-onprem chart only"

# Ensure /tmp is at the front of PATH so our wrapper is found first
export PATH="/tmp:${PATH}"
echo "PATH updated: /tmp is now first in PATH"
echo "helm resolves to: $(command -v helm)"

echo "========== Configuring OpenShift SecurityContextConstraints =========="
# Grant anyuid SCC to allow pods to run with runAsUser: 1000 when using storageType=minio
# This is needed because the chart uses Kubernetes-style security contexts with minio
NAMESPACE="${NAMESPACE:-cost-onprem}"
echo "Granting anyuid SCC to service accounts in namespace: ${NAMESPACE}"

# Create namespace if it doesn't exist
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Grant anyuid SCC to default and cost-onprem service accounts
oc adm policy add-scc-to-user anyuid -z default -n "${NAMESPACE}" || true
oc adm policy add-scc-to-user anyuid -z cost-onprem -n "${NAMESPACE}" || true

echo "SecurityContextConstraints configured"

echo "========== Running E2E Tests =========="

# Export environment variables for the deployment script
export NAMESPACE="${NAMESPACE:-cost-onprem}"
export VERBOSE="${VERBOSE:-true}"
export USE_LOCAL_CHART="true"

# Run the deployment script from the chart repo source
# The step runs with from: src, so we're already in the chart repo
# Use bash to execute since source may be read-only (can't chmod)
bash ./scripts/deploy-test-cost-onprem.sh \
    --namespace "${NAMESPACE}" \
    --verbose
