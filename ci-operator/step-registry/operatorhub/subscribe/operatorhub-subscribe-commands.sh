#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export SUB_SOURCE="${SUB_SOURCE:-qe-app-registry}"

# Helper function to execute and log commands
function run_command() {
    local CMD="$1"
    echo "DEBUG: Running Command: ${CMD}"
    eval "${CMD}"
}

# Display current environment settings
echo "DEBUG: Current environment variables:"
echo "SUB_INSTALL_NAMESPACE: ${SUB_INSTALL_NAMESPACE}"
echo "SUB_PACKAGE: ${SUB_PACKAGE}"
echo "SUB_CHANNEL: ${SUB_CHANNEL}"
#echo "SUB_SOURCE: ${SUB_SOURCE:-redhat-operators}"
echo "SUB_SOURCE: ${SUB_SOURCE:-qe-app-registry}" 
echo "SUB_SOURCE_NAMESPACE: ${SUB_SOURCE_NAMESPACE:-openshift-marketplace}"

# Check CatalogSource status
echo "DEBUG: Checking CatalogSource status:"
run_command "oc get catalogsource -n openshift-marketplace"
echo "DEBUG: Detailed CatalogSource information:"
run_command "oc describe catalogsource ${SUB_SOURCE} -n openshift-marketplace"

# Check marketplace pods
echo "DEBUG: Checking marketplace pods:"
run_command "oc get pods -n openshift-marketplace"

# Special check for aosqe-index version
if [[ "${SUB_SOURCE}" == "aosqe-index" ]]; then
    echo "DEBUG: Found aosqe-index, checking version:"
    run_command "oc get catalogsource aosqe-index -n openshift-marketplace -o jsonpath='{.spec.image}'"
fi

# Verify available package manifests
echo "DEBUG: Checking available packages from catalog source:"
run_command "oc get packagemanifest -n openshift-marketplace | grep ${SUB_PACKAGE} || true"

# Create namespace if it doesn't exist
if ! oc get ns "${SUB_INSTALL_NAMESPACE}"; then
    echo "DEBUG: Creating namespace ${SUB_INSTALL_NAMESPACE}"
    oc create ns "${SUB_INSTALL_NAMESPACE}"
fi

# Create OperatorGroup for the namespace
echo "DEBUG: Creating OperatorGroup"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${SUB_INSTALL_NAMESPACE}-operator-group"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - "${SUB_INSTALL_NAMESPACE}"
EOF

# Create Subscription for the operator
echo "DEBUG: Creating Subscription"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${SUB_PACKAGE}"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${SUB_CHANNEL}"
  name: "${SUB_PACKAGE}"
  source: "${SUB_SOURCE:-"qe-app-registry"}"
  sourceNamespace: "${SUB_SOURCE_NAMESPACE:-"openshift-marketplace"}"
EOF

# Monitor deployment progress
echo "DEBUG: Monitoring operator deployment..."
for i in $(seq 1 30); do
    echo "DEBUG: Attempt ${i}/30 - Checking subscription status"
    
    # Check subscription status
    echo "DEBUG: Current Subscription status:"
    run_command "oc get subscription ${SUB_PACKAGE} -n ${SUB_INSTALL_NAMESPACE} -o yaml"
    
    # Check CSV (ClusterServiceVersion) status
    echo "DEBUG: ClusterServiceVersion status:"
    run_command "oc get csv -n ${SUB_INSTALL_NAMESPACE}"
    
    # Check related pods
    echo "DEBUG: Pods in namespace ${SUB_INSTALL_NAMESPACE}:"
    run_command "oc get pods -n ${SUB_INSTALL_NAMESPACE}"
    
    # Check recent events
    echo "DEBUG: Recent events in namespace ${SUB_INSTALL_NAMESPACE}:"
    run_command "oc get events -n ${SUB_INSTALL_NAMESPACE} --sort-by='.lastTimestamp' | tail -n 5"
    
    # Check if subscription is successful
    if oc get subscription "${SUB_PACKAGE}" -n "${SUB_INSTALL_NAMESPACE}" \
        -o jsonpath='{.status.state}' | grep -q "AtLatestKnown"; then
        echo "DEBUG: Operator successfully deployed"
        
        # Final status check on success
        echo "DEBUG: Final deployment status:"
        run_command "oc get all -n ${SUB_INSTALL_NAMESPACE}"
        exit 0
    fi
    
    sleep 30
done

# If deployment fails, gather diagnostic information
echo "ERROR: Operator deployment failed"
echo "DEBUG: Final status check:"
run_command "oc get subscription ${SUB_PACKAGE} -n ${SUB_INSTALL_NAMESPACE} -o yaml"
run_command "oc get events -n ${SUB_INSTALL_NAMESPACE} --sort-by='.lastTimestamp'"
run_command "oc get csv -n ${SUB_INSTALL_NAMESPACE}"
run_command "oc get catalogsource -n ${SUB_SOURCE_NAMESPACE}"
run_command "oc describe catalogsource ${SUB_SOURCE} -n ${SUB_SOURCE_NAMESPACE}"

exit 1
