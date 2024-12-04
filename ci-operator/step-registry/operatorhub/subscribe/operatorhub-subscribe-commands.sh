#!/bin/bash

# Enable strict error handling
set -o nounset
set -o errexit
set -o pipefail

# Function to print debug information with error handling
debug_info() {
    echo "=== Debug Information ==="
    
    echo "Checking cluster connection..."
    if ! oc whoami >/dev/null 2>&1; then
        echo "ERROR: Not connected to OpenShift cluster"
        return 1
    fi

    echo "Current user and context:"
    oc whoami
    oc config current-context

    echo -e "\nChecking CatalogSource status..."
    oc get catalogsource -n openshift-marketplace || echo "No CatalogSource found"

    # Check if namespace exists before querying namespace-specific resources
    if oc get namespace "${SUB_INSTALL_NAMESPACE}" >/dev/null 2>&1; then
        echo -e "\nChecking resources in ${SUB_INSTALL_NAMESPACE}:"
        
        echo -e "\nSubscriptions:"
        oc get subscription -n "${SUB_INSTALL_NAMESPACE}" || echo "No subscriptions found"
        
        if oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}" >/dev/null 2>&1; then
            echo -e "\nSubscription details for ${SUB_PACKAGE}:"
            oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}" -o yaml
            
            echo -e "\nSubscription events:"
            oc describe subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}"
        fi
        
        echo -e "\nOperatorGroups:"
        oc get operatorgroup -n "${SUB_INSTALL_NAMESPACE}" || echo "No OperatorGroups found"
        
        echo -e "\nCSVs:"
        oc get csv -n "${SUB_INSTALL_NAMESPACE}" || echo "No CSVs found"
        
        echo -e "\nInstallPlans:"
        oc get installplan -n "${SUB_INSTALL_NAMESPACE}" || echo "No InstallPlans found"
    else
        echo -e "\nNamespace ${SUB_INSTALL_NAMESPACE} does not exist"
    fi
    
    echo -e "\nChecking Pods in openshift-marketplace:"
    oc get pods -n openshift-marketplace || echo "Cannot access pods in openshift-marketplace"
    
    echo "======================"
}

# Function to verify required permissions
check_permissions() {
    echo "Checking required permissions..."
    local required_permissions=("create namespace" "create subscription" "create operatorgroup")
    local missing_permissions=()

    for perm in "${required_permissions[@]}"; do
        if ! oc auth can-i ${perm} >/dev/null 2>&1; then
            missing_permissions+=("${perm}")
        fi
    done

    if [ ${#missing_permissions[@]} -ne 0 ]; then
        echo "ERROR: Missing required permissions:"
        printf '%s\n' "${missing_permissions[@]}"
        return 1
    fi
    
    echo "All required permissions verified"
    return 0
}

# Function to verify environment variables
check_env_vars() {
    local missing_vars=()
    
    declare -a required_vars=(
        "SUB_INSTALL_NAMESPACE"
        "SUB_PACKAGE"
        "SUB_CHANNEL"
        "SUB_SOURCE"
    )

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -ne 0 ]; then
        echo "ERROR: Missing required environment variables:"
        printf '%s\n' "${missing_vars[@]}"
        return 1
    fi

    # Print current environment settings
    echo "Environment variables:"
    echo "SUB_INSTALL_NAMESPACE: ${SUB_INSTALL_NAMESPACE}"
    echo "SUB_PACKAGE: ${SUB_PACKAGE}"
    echo "SUB_CHANNEL: ${SUB_CHANNEL}"
    echo "SUB_SOURCE: ${SUB_SOURCE}"
    echo "SUB_TARGET_NAMESPACES: ${SUB_TARGET_NAMESPACES:-${SUB_INSTALL_NAMESPACE}}"
    
    return 0
}

# Function to create and verify namespace
create_namespace() {
    echo "Creating namespace ${SUB_INSTALL_NAMESPACE}..."
    
    if ! oc get namespace "${SUB_INSTALL_NAMESPACE}" >/dev/null 2>&1; then
        if ! oc create namespace "${SUB_INSTALL_NAMESPACE}"; then
            echo "ERROR: Failed to create namespace ${SUB_INSTALL_NAMESPACE}"
            return 1
        fi
        
        # Wait for namespace to be fully created
        local retries=10
        for ((i=1; i<=retries; i++)); do
            if oc get namespace "${SUB_INSTALL_NAMESPACE}" >/dev/null 2>&1; then
                echo "Namespace ${SUB_INSTALL_NAMESPACE} created successfully"
                return 0
            fi
            echo "Waiting for namespace to be ready... (${i}/${retries})"
            sleep 2
        done
        
        echo "ERROR: Namespace creation verification timed out"
        return 1
    else
        echo "Namespace ${SUB_INSTALL_NAMESPACE} already exists"
        return 0
    fi
}

# Main script execution starts here
echo "Starting operator installation process..."

# Verify prerequisites
check_permissions || exit 1
check_env_vars || exit 1

# Handle target namespaces
if [[ "${SUB_TARGET_NAMESPACES:-}" == "!install" ]]; then
    SUB_TARGET_NAMESPACES="${SUB_INSTALL_NAMESPACE}"
fi

echo "Installing ${SUB_PACKAGE} from ${SUB_CHANNEL} into ${SUB_INSTALL_NAMESPACE}, targeting ${SUB_TARGET_NAMESPACES}"

# Print initial state
echo "Initial environment state:"
debug_info

# Create namespace with verification
create_namespace || exit 1

# Create OperatorGroup
echo "Creating OperatorGroup..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${SUB_INSTALL_NAMESPACE}-operator-group"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# Create Subscription
echo "Creating Subscription..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${SUB_PACKAGE}"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${SUB_PACKAGE}"
  source: "${SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# Print state after creating resources
echo "State after creating resources:"
debug_info

# Wait for operator installation
echo "Waiting 60 seconds before checking installation status..."
sleep 60

# Monitor installation progress
RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
    if [[ -z "${CSV}" ]]; then
        CSV=$(oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null)
        
        if [[ -z "${CSV}" ]]; then
            echo "Try ${i}/${RETRIES}: Waiting for CSV... Current subscription status:"
            oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}" -o yaml
            sleep 30
            continue
        fi
    fi

    CSV_STATUS=$(oc get csv -n "${SUB_INSTALL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [[ "${CSV_STATUS}" == "Succeeded" ]]; then
        echo "${SUB_PACKAGE} installation succeeded"
        break
    else
        echo "Try ${i}/${RETRIES}: Installation in progress. CSV Status: ${CSV_STATUS}"
        echo "CSV Details:"
        oc get csv -n "${SUB_INSTALL_NAMESPACE}" "${CSV}" -o yaml
        
        if [[ $i == "${RETRIES}" ]]; then
            echo "ERROR: Installation timed out"
            debug_info
            exit 1
        fi
        sleep 30
    fi
done

# Verify final status
if [[ -z "${CSV}" ]] || [[ $(oc get csv -n "${SUB_INSTALL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}' 2>/dev/null) != "Succeeded" ]]; then
    echo "ERROR: Failed to deploy ${SUB_PACKAGE}"
    debug_info
    
    if [[ -n "${CSV}" ]]; then
        echo "CSV ${CSV} details:"
        oc get csv "${CSV}" -n "${SUB_INSTALL_NAMESPACE}" -o yaml
        oc describe csv "${CSV}" -n "${SUB_INSTALL_NAMESPACE}"
    fi
    
    echo "InstallPlan status:"
    oc get installplan -n "${SUB_INSTALL_NAMESPACE}"
    
    exit 1
fi

echo "Successfully installed ${SUB_PACKAGE}"
