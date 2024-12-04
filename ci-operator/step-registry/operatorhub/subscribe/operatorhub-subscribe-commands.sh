#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Function to print debug information
debug_info() {
    echo "=== Debug Information ==="
    echo "Checking CatalogSource status..."
    oc get catalogsource -n openshift-marketplace
    
    echo -e "\nChecking Subscription..."
    oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}" -o yaml
    
    echo -e "\nChecking Subscription Events..."
    oc describe subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}"
    
    echo -e "\nChecking OperatorGroup..."
    oc get operatorgroup -n "${SUB_INSTALL_NAMESPACE}" -o yaml
    
    echo -e "\nChecking Pods in openshift-marketplace..."
    oc get pods -n openshift-marketplace
    
    echo "======================"
}

# Check required environment variables
if [[ -z "${SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${SUB_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ -z "${SUB_SOURCE}" ]]; then
  echo "ERROR: SUB_SOURCE is not defined"
  exit 1
fi

if [[ "${SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  SUB_TARGET_NAMESPACES="${SUB_INSTALL_NAMESPACE}"
fi

echo "Installing ${SUB_PACKAGE} from ${SUB_CHANNEL} into ${SUB_INSTALL_NAMESPACE}, targeting ${SUB_TARGET_NAMESPACES}"

# Print initial environment state
echo "Initial environment state:"
debug_info

# Create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${SUB_INSTALL_NAMESPACE}"
EOF

# Deploy new operator group
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

# Subscribe to the operator
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

# Sleep before starting to watch
echo "Waiting 60 seconds before checking installation status..."
sleep 60

RETRIES=30
CSV=
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
    
    # Print subscription status if CSV is empty
    if [[ -z "${CSV}" ]]; then
      echo "Try ${i}/${RETRIES}: Subscription status:"
      oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${SUB_PACKAGE}" -o yaml
    fi
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: can't get the ${SUB_PACKAGE} yet. Checking again in 30 seconds"
    sleep 30
    continue
  fi

  CSV_STATUS=$(oc get csv -n ${SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  
  if [[ "${CSV_STATUS}" == "Succeeded" ]]; then
    echo "${SUB_PACKAGE} is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: ${SUB_PACKAGE} is not deployed yet. CSV Status: ${CSV_STATUS}"
    echo "CSV Details:"
    oc get csv -n "${SUB_INSTALL_NAMESPACE}" "${CSV}" -o yaml
    sleep 30
  fi
done

# Check final status
if [[ -z "${CSV}" ]] || [[ $(oc get csv -n "${SUB_INSTALL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}' 2>/dev/null) != "Succeeded" ]]; then
  echo "Error: Failed to deploy ${SUB_PACKAGE}"
  echo "Final debug information:"
  debug_info
  
  if [[ -n "${CSV}" ]]; then
    echo "CSV ${CSV} YAML"
    oc get csv "${CSV}" -n "${SUB_INSTALL_NAMESPACE}" -o yaml
    echo
    echo "CSV ${CSV} Describe"
    oc describe csv "${CSV}" -n "${SUB_INSTALL_NAMESPACE}"
  fi
  
  # Check for install plan
  echo "Checking InstallPlan status:"
  oc get installplan -n "${SUB_INSTALL_NAMESPACE}"
  
  exit 1
fi

echo "successfully installed ${SUB_PACKAGE}"
