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
    curl -sL "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /tmp/kubectl
    chmod +x /tmp/kubectl
    export PATH="/tmp:${PATH}"
    echo "kubectl installed successfully"
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
if [ -f "${SHARED_DIR}/minio-endpoint" ]; then
    MINIO_ENDPOINT=$(cat "${SHARED_DIR}/minio-endpoint")
    export MINIO_ENDPOINT
    MINIO_ACCESS_KEY=$(cat "${SHARED_DIR}/minio-access-key")
    export MINIO_ACCESS_KEY
    MINIO_SECRET_KEY=$(cat "${SHARED_DIR}/minio-secret-key")
    export MINIO_SECRET_KEY
    MINIO_NAMESPACE=$(cat "${SHARED_DIR}/minio-namespace")
    export MINIO_NAMESPACE
    echo "MinIO endpoint: ${MINIO_ENDPOINT}"
    echo "MinIO namespace: ${MINIO_NAMESPACE}"
else
    echo "WARNING: MinIO configuration not found in SHARED_DIR"
    echo "Make sure insights-onprem-minio-deploy step ran before this step"
fi

# Read application namespace from SHARED_DIR and export as NAMESPACE
# This overrides the CI's NAMESPACE var so the helm chart deploys to the right place
if [ -f "${SHARED_DIR}/minio-env" ]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/minio-env"
    if [ -n "${APP_NAMESPACE:-}" ]; then
        export NAMESPACE="${APP_NAMESPACE}"
        echo "Application namespace: ${NAMESPACE}"
    fi
fi

echo "========== Installing Cost Management Operator =========="
# Pre-install the Cost Management Operator without startingCSV
# This ensures the operator is installed with whatever version is available in the catalog
# The upstream setup-cost-mgmt-tls.sh will skip installation if it's already present

# Use the application namespace (defaults to cost-onprem)
COST_MGMT_NAMESPACE="${NAMESPACE:-cost-onprem}"
echo "Installing Cost Management Operator in namespace: ${COST_MGMT_NAMESPACE}"

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
  channel: stable
  name: costmanagement-metrics-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    echo "Waiting for Cost Management Operator to be ready..."
    # Wait for the CSV to be installed (up to 5 minutes)
    TIMEOUT=300
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        if oc get csv -n "${COST_MGMT_NAMESPACE}" 2>/dev/null | grep -q "costmanagement-metrics-operator.*Succeeded"; then
            echo "Cost Management Operator installed successfully"
            break
        fi
        echo "Waiting for operator CSV to succeed... (${ELAPSED}s elapsed)"
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done

    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "WARNING: Timeout waiting for Cost Management Operator, continuing anyway..."
        oc get csv -n "${COST_MGMT_NAMESPACE}" || true
        oc get subscription -n "${COST_MGMT_NAMESPACE}" -o yaml || true
    fi
fi

echo "========== Image Tag Resolution =========="

export IMAGE_TAG

# Get job type and PR information from JOB_SPEC
JOB_TYPE=$(echo "${JOB_SPEC}" | jq -r '.type // "presubmit"')
echo "JOB_TYPE: ${JOB_TYPE}"

if [ "${JOB_TYPE}" == "presubmit" ] && [[ "${JOB_NAME}" != rehearse-* ]]; then
    echo "Running as presubmit job - resolving PR-based image tag"
    
    # Extract PR number and SHA from JOB_SPEC
    GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
    echo "GIT_PR_NUMBER: ${GIT_PR_NUMBER}"
    
    # Get the PR commit SHA
    LONG_SHA=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].sha')
    SHORT_SHA=$(echo "${LONG_SHA}" | cut -c1-8)
    echo "SHORT_SHA: ${SHORT_SHA}"
    
    # Construct image tag: pr-<number>-<short-sha>
    IMAGE_TAG="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
    echo "Constructed IMAGE_TAG: ${IMAGE_TAG}"
    
    # Full image reference
    IMAGE_NAME="${QUAY_REPO}:${IMAGE_TAG}"
    echo "IMAGE_NAME: ${IMAGE_NAME}"
    
    echo "========== Waiting for Docker Image Availability =========="
    # Extract repository path from full quay URL
    REPO_PATH=$(echo "${QUAY_REPO}" | sed 's|^quay.io/||')
    
    # Timeout configuration for waiting for Docker image availability
    MAX_WAIT_TIME_SECONDS=$((60*60))  # Maximum wait time: 60 minutes
    POLL_INTERVAL_SECONDS=60          # Check every 60 seconds
    ELAPSED_TIME=0
    
    echo "Waiting for image ${IMAGE_NAME} to be available..."
    
    while true; do
        # Check image availability on Quay.io
        response=$(curl -s "https://quay.io/api/v1/repository/${REPO_PATH}/tag/?specificTag=${IMAGE_TAG}")
        
        # Use jq to parse the JSON and see if the tag exists
        tag_count=$(echo "${response}" | jq '.tags | length')
        
        if [ "${tag_count}" -gt "0" ]; then
            echo "Docker image ${IMAGE_NAME} is now available. Time elapsed: $((ELAPSED_TIME / 60)) minute(s)."
            break
        fi
        
        echo "Image not yet available. Waiting ${POLL_INTERVAL_SECONDS}s... (elapsed: $((ELAPSED_TIME / 60))m)"
        
        # Wait for the interval duration
        sleep ${POLL_INTERVAL_SECONDS}
        
        # Increment the elapsed time
        ELAPSED_TIME=$((ELAPSED_TIME + POLL_INTERVAL_SECONDS))
        
        # If the elapsed time exceeds the timeout, exit with an error
        if [ ${ELAPSED_TIME} -ge ${MAX_WAIT_TIME_SECONDS} ]; then
            echo "Timed out waiting for Docker image ${IMAGE_NAME}. Time elapsed: $((ELAPSED_TIME / 60)) minute(s)."
            echo "Please verify that the image build job completed successfully."
            exit 1
        fi
    done
else
    echo "Not a presubmit job or is a rehearsal - using default image tag"
    IMAGE_TAG="${IMAGE_TAG_DEFAULT}"
    echo "IMAGE_TAG: ${IMAGE_TAG}"
fi

echo "========== Final Image Configuration =========="
echo "Using Image: ${QUAY_REPO}:${IMAGE_TAG}"

echo "========== Configuring Helm for MinIO Storage =========="
# Tell the Helm chart to use MinIO instead of ODF (NooBaa)
# This prevents the chart from trying to lookup NooBaa CRDs which don't exist
# when using MinIO for object storage

# The deploy-test-ros.sh script sets HELM_EXTRA_ARGS for image overrides.
# We need to add our MinIO configuration to HELM_EXTRA_ARGS as well.
# This ensures global.storageType=minio is passed regardless of what the upstream
# scripts do with HELM_EXTRA_ARGS or VALUES_FILE.

HELM_WRAPPER="/tmp/helm-wrapper"
ORIGINAL_HELM=$(command -v helm)

cat > "${HELM_WRAPPER}" << 'WRAPPER_EOF'
#!/bin/bash
# Helm wrapper that injects MinIO storage configuration
# This intercepts helm calls and adds --set global.storageType=minio

ORIGINAL_HELM="__ORIGINAL_HELM__"
MINIO_ACCESS_KEY="__MINIO_ACCESS_KEY__"
MINIO_SECRET_KEY="__MINIO_SECRET_KEY__"

# Check if this is an install/upgrade command that needs our overrides
if [[ "$*" == *"upgrade"* ]] || [[ "$*" == *"install"* ]]; then
    echo "[helm-wrapper] Injecting MinIO storage configuration..."
    exec "$ORIGINAL_HELM" "$@" \
        --set "global.storageType=minio" \
        --set "minio.rootUser=${MINIO_ACCESS_KEY}" \
        --set "minio.rootPassword=${MINIO_SECRET_KEY}"
else
    # For other helm commands, pass through unchanged
    exec "$ORIGINAL_HELM" "$@"
fi
WRAPPER_EOF

# Replace placeholders with actual values
sed -i "s|__ORIGINAL_HELM__|${ORIGINAL_HELM}|g" "${HELM_WRAPPER}"
sed -i "s|__MINIO_ACCESS_KEY__|${MINIO_ACCESS_KEY:-minioadmin}|g" "${HELM_WRAPPER}"
sed -i "s|__MINIO_SECRET_KEY__|${MINIO_SECRET_KEY:-minioadmin}|g" "${HELM_WRAPPER}"

chmod +x "${HELM_WRAPPER}"

# Prepend /tmp to PATH so our wrapper is found first
export PATH="/tmp:${PATH}"
# Also create a symlink so 'helm' resolves to our wrapper
ln -sf "${HELM_WRAPPER}" /tmp/helm

echo "Helm wrapper installed at /tmp/helm"
echo "Original helm: ${ORIGINAL_HELM}"
echo "MinIO storage type will be injected into helm upgrade/install commands"

echo "========== Running E2E Tests =========="
export IMAGE_TAG
make oc-deploy-test

