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
    curl -sL https://get.helm.sh/helm-v4.0.4-linux-amd64.tar.gz -o /tmp/helm.tar.gz
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

echo "========== Object Storage Configuration =========="

if [ "${DEPLOY_S4:-false}" == "true" ]; then
    echo "Deploying S4 storage to namespace: ${S4_NAMESPACE:-s4-test}"
    echo "S4 configuration will be handled by deploy-test-cost-onprem.sh"
else
    echo "Skipping S4 deployment (DEPLOY_S4=false)"
    echo "Storage will be handled externally or is not required"
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

echo "========== Resolving Chart Reference =========="

# ============================================================================
# Chart Tag Resolution for Nightly Jobs
# ============================================================================
# CHART_REF can be: "release", "rc", "main", or an explicit tag/branch
# For nightly jobs, this allows testing specific release types
#
# - "release": Latest released (non-RC) chart version
# - "rc": Latest release candidate version
# - "main": Current main branch (bleeding edge)
#
# For RC resolution, we first check if the deployment script supports --devel
# (which tells Helm to include pre-release versions). If supported, we pass
# that flag instead of checking out a specific tag. This allows testing the
# chart from the Helm repo with RC versions included.
#
# Fallback: If --devel is not supported, we resolve the latest RC tag via git.

# Check if deploy script supports --devel flag
check_devel_support() {
    if [[ -f "./scripts/deploy-test-cost-onprem.sh" ]]; then
        if grep -q -- '--devel' ./scripts/deploy-test-cost-onprem.sh 2>/dev/null; then
            echo "true"
        else
            echo "false"
        fi
    else
        echo "false"
    fi
}

resolve_chart_ref() {
    local chart_ref="${CHART_REF:-main}"
    local devel_supported
    devel_supported=$(check_devel_support)

    case "$chart_ref" in
        release)
            # Get latest released (non-RC) tag (e.g., cost-onprem-0.2.19)
            echo "Resolving latest release tag..."
            local latest_release
            latest_release=$(git tag -l "cost-onprem-*" 2>/dev/null | grep -v '\-rc' | sort -V | tail -1)
            if [[ -n "$latest_release" ]]; then
                echo "Found latest release: $latest_release"
                echo "$latest_release"
            else
                echo "WARNING: No release tags found, using main"
                echo "main"
            fi
            ;;
        rc)
            # For RC, prefer using --devel flag if script supports it
            if [[ "$devel_supported" == "true" ]]; then
                echo "Deploy script supports --devel flag, will use Helm pre-release resolution"
                # Return special marker to indicate --devel should be used
                echo "USE_DEVEL_FLAG"
            else
                # Fallback: resolve latest RC tag via git
                echo "Resolving latest RC tag via git (--devel not supported)..."
                local latest_rc
                latest_rc=$(git tag -l "cost-onprem-*-rc*" 2>/dev/null | sort -V | tail -1)
                if [[ -n "$latest_rc" ]]; then
                    echo "Found latest RC: $latest_rc"
                    echo "$latest_rc"
                else
                    echo "WARNING: No RC tags found, skipping RC test"
                    echo ""
                fi
            fi
            ;;
        main)
            # Use HEAD of main branch
            echo "Using main branch"
            echo "main"
            ;;
        *)
            # Explicit tag or branch
            echo "Using explicit ref: $chart_ref"
            echo "$chart_ref"
            ;;
    esac
}

# Resolve chart reference if CHART_REF is set
USE_HELM_DEVEL="false"
if [[ -n "${CHART_REF:-}" ]]; then
    RESOLVED_REF=$(resolve_chart_ref)
    
    if [[ "$RESOLVED_REF" == "USE_DEVEL_FLAG" ]]; then
        # Script supports --devel, we'll pass that flag instead of checking out a tag
        echo "Will use --devel flag for Helm to include pre-release (RC) versions"
        USE_HELM_DEVEL="true"
        RESOLVED_REF="main"  # Stay on main, let Helm resolve the RC
    elif [[ -z "$RESOLVED_REF" ]]; then
        echo "No matching chart reference found for CHART_REF=${CHART_REF}, exiting gracefully"
        echo "skipped" > "${ARTIFACT_DIR}/test_status.txt"
        exit 0
    fi

    if [[ "$RESOLVED_REF" != "main" ]]; then
        echo "Checking out chart reference: $RESOLVED_REF"
        git fetch --tags origin
        git checkout "$RESOLVED_REF"
        echo "Now at: $(git describe --tags --always)"
    fi

    # Export for version_info.json and downstream scripts
    export CHART_REF_RESOLVED="$RESOLVED_REF"
    export USE_HELM_DEVEL
else
    echo "No CHART_REF set, using current source (PR or main branch)"
fi

echo "========== Running E2E Tests =========="

# Export environment variables for the deployment script
export NAMESPACE="${NAMESPACE:-cost-onprem}"
export VERBOSE="${VERBOSE:-true}"
export USE_LOCAL_CHART="true"
export COST_MGMT_NAMESPACE="${NAMESPACE}"
export COST_MGMT_RELEASE_NAME="${HELM_RELEASE_NAME:-cost-onprem}"

# Build deployment script arguments
DEPLOY_ARGS=(
    --namespace "${NAMESPACE}"
    --verbose
    --save-versions
)

# Add S4 storage flags if enabled
if [ "${DEPLOY_S4:-false}" == "true" ]; then
    DEPLOY_ARGS+=(--deploy-s4)
    # Use the same namespace as the application for S4 if S4_NAMESPACE is not explicitly set
    # This ensures the storage credentials secret is created in the correct namespace
    DEPLOY_ARGS+=(--s4-namespace "${S4_NAMESPACE:-${NAMESPACE}}")
fi

# Add --devel flag if we're testing RC via Helm pre-release resolution
if [ "${USE_HELM_DEVEL:-false}" == "true" ]; then
    echo "Adding --devel flag for Helm pre-release (RC) chart resolution"
    DEPLOY_ARGS+=(--devel)
fi

# Add IQE test flags if enabled
if [ "${RUN_IQE:-false}" == "true" ]; then
    echo "IQE tests enabled with profile: ${IQE_PROFILE:-smoke}"
    DEPLOY_ARGS+=(--run-iqe)
    DEPLOY_ARGS+=(--iqe-profile "${IQE_PROFILE:-smoke}")
    DEPLOY_ARGS+=(--listener-cpu "${LISTENER_CPU:-max}")
    
    # Set up Quay pull secret for IQE image
    SECRETS_DIR="/tmp/secrets/ci"
    if [[ -f "${SECRETS_DIR}/username" ]] && [[ -f "${SECRETS_DIR}/password" ]]; then
        echo "Creating Quay pull secret for IQE image..."
        # Disable tracing due to password handling
        [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
        set +x
        QUAY_USER=$(cat "${SECRETS_DIR}/username")
        QUAY_PASS=$(cat "${SECRETS_DIR}/password")
        oc create secret docker-registry iqe-pull-secret \
            --docker-server=quay.io \
            --docker-username="${QUAY_USER}" \
            --docker-password="${QUAY_PASS}" \
            -n "${NAMESPACE}" \
            --dry-run=client -o yaml | oc apply -f -
        $WAS_TRACING && set -x
        echo "Quay pull secret created"
    else
        echo "WARNING: Quay credentials not found at ${SECRETS_DIR}, IQE image pull may fail"
    fi
fi

# Run the deployment script from the chart repo source
# The step runs with from: src, so we're already in the chart repo
# Use bash to execute since source may be read-only (can't chmod)
bash ./scripts/deploy-test-cost-onprem.sh "${DEPLOY_ARGS[@]}"

# Copy test artifacts to CI artifact directory
echo "========== Collecting Test Artifacts =========="
if [ -d "./tests/reports" ]; then
    echo "Found test reports directory, copying artifacts..."
    
    # Copy all files from reports directory
    cp -r ./tests/reports/* "${ARTIFACT_DIR}/" 2>/dev/null || true
    
    # Rename junit files for Prow recognition (must be prefixed with junit)
    # IQE test results
    if [ -f "${ARTIFACT_DIR}/iqe_junit.xml" ]; then
        mv "${ARTIFACT_DIR}/iqe_junit.xml" "${ARTIFACT_DIR}/junit_iqe.xml"
        echo "  - junit_iqe.xml (IQE test results)"
    fi
    
    # Chart pytest results
    if [ -f "${ARTIFACT_DIR}/junit.xml" ]; then
        mv "${ARTIFACT_DIR}/junit.xml" "${ARTIFACT_DIR}/junit_chart.xml"
        echo "  - junit_chart.xml (chart test results)"
    fi
    
    # HTML report
    if [ -f "${ARTIFACT_DIR}/report.html" ]; then
        echo "  - report.html (HTML test report)"
    fi
    
    # IQE output log
    if [ -f "${ARTIFACT_DIR}/iqe_output.log" ]; then
        echo "  - iqe_output.log (IQE test output)"
    fi
    
    # Screenshots directory
    if [ -d "${ARTIFACT_DIR}/screenshots" ]; then
        echo "  - screenshots/ (UI test screenshots)"
    fi
    
    echo "Artifacts collected to ${ARTIFACT_DIR}"
else
    echo "No test reports directory found"
fi

# Copy JUnit files to SHARED_DIR for ReportPortal post step
# (ARTIFACT_DIR is step-specific; SHARED_DIR persists across steps)
echo "Copying JUnit files to SHARED_DIR for ReportPortal..."
cp "${ARTIFACT_DIR}"/junit_*.xml "${SHARED_DIR}/" 2>/dev/null || true
ls "${SHARED_DIR}"/junit_*.xml 2>/dev/null | sed 's/^/  - /' || echo "  (no junit files to copy)"

# Copy version_info.json for ReportPortal metadata
if [ -f "./version_info.json" ]; then
    cp ./version_info.json "${ARTIFACT_DIR}/version_info.json"
    # Also copy to SHARED_DIR for ReportPortal step
    cp ./version_info.json "${SHARED_DIR}/version_info.json"
    echo "  - version_info.json (component version metadata)"
else
    echo "No version_info.json found, skipping"
fi

# Capture IQE listener pod logs if IQE was run
if [ "${RUN_IQE:-false}" == "true" ]; then
    echo "Collecting IQE listener pod logs..."
    IQE_LISTENER_POD=$(oc get pods -n "${NAMESPACE}" -l app=iqe-listener --no-headers -o name 2>/dev/null | head -1)
    if [ -n "${IQE_LISTENER_POD}" ]; then
        oc logs -n "${NAMESPACE}" "${IQE_LISTENER_POD}" \
            > "${ARTIFACT_DIR}/iqe_listener.log" 2>/dev/null || true
        echo "  - iqe_listener.log (IQE data listener output)"
    else
        echo "No IQE listener pod found, skipping log collection"
    fi
fi
