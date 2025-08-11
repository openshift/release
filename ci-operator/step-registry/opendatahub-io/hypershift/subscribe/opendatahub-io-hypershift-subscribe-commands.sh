#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ============================================================================
# Constants and Configuration
# ============================================================================
readonly CATALOG_SOURCE_NAME="custom-catalog-source"
readonly MAX_INSTALL_ATTEMPTS=30
readonly INSTALL_RETRY_DELAY=20

# ============================================================================
# Utility Functions
# ============================================================================

# Function for consistent logging with timestamps
log() {
    echo "[$(date --utc +%FT%T.%3NZ)] $*"
}

# Function for error logging and exit
error_exit() {
    log "ERROR: $*"
    exit 1
}

# Function to apply Kubernetes resources from template
apply_k8s_resource() {
    local resource_type="$1"
    local template="$2"
    
    log "Creating ${resource_type}"
    if ! echo "${template}" | oc apply -f -; then
        error_exit "Failed to create ${resource_type}"
    fi
}

# ============================================================================
# Kubernetes Resource Templates
# ============================================================================

# Generate CatalogSource template
generate_catalog_source_template() {
    cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
  namespace: ${OO_INSTALL_NAMESPACE}
spec:
  sourceType: grpc
  image: ${OO_INDEX}
  displayName: "Custom Catalog for ${OO_PACKAGE}"
EOF
}

# Generate OperatorGroup template
generate_operator_group_template() {
    cat <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${OO_INSTALL_NAMESPACE}-operator-group
  namespace: ${OO_INSTALL_NAMESPACE}
spec:
  ${TARGET_NS_YAML}
EOF
}

# Generate base Subscription template
generate_subscription_template() {
    cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OO_PACKAGE}
  namespace: ${OO_INSTALL_NAMESPACE}
spec:
  channel: ${OO_CHANNEL}
  installPlanApproval: Automatic
  name: ${OO_PACKAGE}
  source: ${CATALOG_SOURCE_NAME}
  sourceNamespace: ${OO_INSTALL_NAMESPACE}
EOF
}

# ============================================================================
# Configuration Functions
# ============================================================================

# Validate required environment variables
validate_parameters() {
    local missing_params=()
    
    [[ -z ${OO_INDEX:-} ]] && missing_params+=("OO_INDEX")
    [[ -z ${OO_PACKAGE:-} ]] && missing_params+=("OO_PACKAGE")
    [[ -z ${OO_CHANNEL:-} ]] && missing_params+=("OO_CHANNEL")
    [[ -z ${OO_INSTALL_NAMESPACE:-} ]] && missing_params+=("OO_INSTALL_NAMESPACE")
    
    if [[ ${#missing_params[@]} -gt 0 ]]; then
        log "ERROR: Required variables missing: ${missing_params[*]}"
        log "Current values:"
        log "  OO_INDEX: ${OO_INDEX:-MISSING}"
        log "  OO_PACKAGE: ${OO_PACKAGE:-MISSING}"
        log "  OO_CHANNEL: ${OO_CHANNEL:-MISSING}"
        log "  OO_INSTALL_NAMESPACE: ${OO_INSTALL_NAMESPACE:-MISSING}"
        exit 1
    fi
}


display_configuration() {
    log "Configuration:"
    log "  Package: ${OO_PACKAGE}"
    log "  Channel: ${OO_CHANNEL}"
    log "  Install Namespace: ${OO_INSTALL_NAMESPACE}"
    log "  Target Namespaces: ${OO_TARGET_NAMESPACES}"
    log "  Index Image: ${OO_INDEX}"
}

# Configure target namespaces for OperatorGroup
configure_target_namespaces() {
    case "${OO_TARGET_NAMESPACES}" in
        "!install")
            log "Setting target namespaces to installation namespace"
            TARGET_NS_YAML="targetNamespaces: [\"${OO_INSTALL_NAMESPACE}\"]"
            ;;
        "!all")
            log "Targeting all namespaces"
            TARGET_NS_YAML="targetNamespaces: []"
            ;;
        *)
            log "Setting specific target namespaces: ${OO_TARGET_NAMESPACES}"
            # Convert comma-separated list to YAML array
            TARGET_NS_ARRAY=$(echo "${OO_TARGET_NAMESPACES}" | sed 's/,/", "/g' | sed 's/^/["/' | sed 's/$/"]/')
            TARGET_NS_YAML="targetNamespaces: ${TARGET_NS_ARRAY}"
            ;;
    esac
}

# Add environment variables to subscription template if provided
add_subscription_config() {
    local base_template="$1"
    
    if [[ -z "${OO_CONFIG_ENVVARS:-}" ]]; then
        echo "${base_template}"
        return
    fi
    
    log "Adding operator configuration environment variables"
    local config_yaml=""
    IFS=',' read -ra envvars <<< "${OO_CONFIG_ENVVARS}"
    
    for envvar in "${envvars[@]}"; do
        if [[ "${envvar}" == *"="* ]]; then
            local key="${envvar%%=*}"
            local value="${envvar#*=}"
            config_yaml+="      - name: ${key}
        value: ${value}
"
        fi
    done
    
    if [[ -n "${config_yaml}" ]]; then
        echo "${base_template}
  config:
    env:
${config_yaml}"
    else
        echo "${base_template}"
    fi
}

# ============================================================================
# Installation Steps
# ============================================================================

# Step 1: Create installation namespace
create_namespace() {
    log "Step 1: Creating installation namespace"
    if oc create namespace "${OO_INSTALL_NAMESPACE}" 2>/dev/null; then
        log "Created namespace: ${OO_INSTALL_NAMESPACE}"
    else
        log "Namespace ${OO_INSTALL_NAMESPACE} already exists"
    fi
}

# Step 2: Create CatalogSource from custom index
create_catalog_source() {
    log "Step 2: Creating CatalogSource from custom index"
    local template
    template=$(generate_catalog_source_template)
    apply_k8s_resource "CatalogSource" "${template}"
}

# Step 3: Wait for CatalogSource readiness
wait_for_catalog_source() {
    log "Step 3: Waiting for CatalogSource to be ready"
    
    local attempts=60  # 5 minutes with 5-second intervals
    local attempt=1
    
    while [[ ${attempt} -le ${attempts} ]]; do
        local state
        state=$(oc get catalogsource "${CATALOG_SOURCE_NAME}" -n "${OO_INSTALL_NAMESPACE}" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        
        log "Attempt ${attempt}/${attempts}: CatalogSource state: ${state}"
        
        if [[ "${state}" == "READY" ]]; then
            log "CatalogSource is ready"
            return 0
        elif [[ "${state}" == "CONNECTING" || "${state}" == "" ]]; then
            log "CatalogSource still connecting, waiting..."
        else
            log "WARNING: CatalogSource in unexpected state: ${state}"
        fi
        
        sleep 5
        ((attempt++))
    done
    
    # Timeout - provide debug information
    log "ERROR: CatalogSource failed to become ready after 5 minutes"
    log "Final CatalogSource status:"
    oc get catalogsource "${CATALOG_SOURCE_NAME}" -n "${OO_INSTALL_NAMESPACE}" -o yaml
    exit 1
}

# Step 4: Create OperatorGroup
create_operator_group() {
    log "Step 4: Creating OperatorGroup"
    local template
    template=$(generate_operator_group_template)
    apply_k8s_resource "OperatorGroup" "${template}"
}

# Step 5: Create Subscription with optional configuration
create_subscription() {
    log "Step 5: Creating Subscription"
    local base_template subscription_template
    
    base_template=$(generate_subscription_template)
    subscription_template=$(add_subscription_config "${base_template}")
    apply_k8s_resource "Subscription" "${subscription_template}"
}

# Step 6: Wait for operator installation with robust retry logic
wait_for_operator_installation() {
    log "Step 6: Waiting for operator installation"
    
    local csv=""
    local attempt=1
    
    while [[ ${attempt} -le ${MAX_INSTALL_ATTEMPTS} ]]; do
        csv=$(oc get subscription -n "${OO_INSTALL_NAMESPACE}" "${OO_PACKAGE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
        
        if [[ -n "${csv}" ]]; then
            local csv_phase
            csv_phase=$(oc get csv -n "${OO_INSTALL_NAMESPACE}" "${csv}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
            log "Attempt ${attempt}/${MAX_INSTALL_ATTEMPTS}: CSV ${csv} phase: ${csv_phase}"
            
            case "${csv_phase}" in
                "Succeeded")
                    log "Operator ${OO_PACKAGE} installed successfully (CSV: ${csv})"
                    CSV="${csv}"
                    return 0
                    ;;
                "Failed")
                    error_exit "CSV installation failed. See debug output above"
                    ;;
            esac
        else
            log "Attempt ${attempt}/${MAX_INSTALL_ATTEMPTS}: Waiting for CSV to be created..."
        fi
        
        sleep "${INSTALL_RETRY_DELAY}"
        ((attempt++))
    done
    
    # Provide debug information on timeout
    log "Operator installation timed out. Collecting debug information:"
    oc get subscription,installplan,csv -n "${OO_INSTALL_NAMESPACE}" || true
    oc get catalogsource -n "${OO_INSTALL_NAMESPACE}" || true
    [[ -n "${csv}" ]] && oc describe csv "${csv}" -n "${OO_INSTALL_NAMESPACE}" || true
    
    error_exit "Operator installation failed or timed out after ${MAX_INSTALL_ATTEMPTS} attempts"
}

# Generate deployment details template
generate_deployment_details_template() {
    cat <<EOF
---
operator_package: "${OO_PACKAGE}"
operator_channel: "${OO_CHANNEL}"
install_namespace: "${OO_INSTALL_NAMESPACE}"
target_namespaces: "${OO_TARGET_NAMESPACES}"
csv: "${CSV}"
catalog_source: "${CATALOG_SOURCE_NAME}"
index_image: "${OO_INDEX}"
deployment_time: "$(date --utc +%FT%T.%3NZ)"
EOF
}

# ============================================================================
# Main Execution Flow
# ============================================================================

main() {
    # Setup and validation
    export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
    log "Using hosted cluster kubeconfig: ${KUBECONFIG}"
    log "Connected to cluster: $(oc whoami --show-server || echo 'Unable to connect')"
    
    validate_parameters
    display_configuration
    configure_target_namespaces
    
    # Installation steps
    create_namespace
    create_catalog_source
    wait_for_catalog_source
    create_operator_group
    create_subscription
    wait_for_operator_installation
    
    # Finalization
    log "HyperShift operator subscription installation completed successfully"
}

# Execute main function
main "$@"