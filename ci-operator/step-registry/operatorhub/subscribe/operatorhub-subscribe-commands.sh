#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "DEBUG: Starting operator subscription process"
echo "DEBUG: SUB_INSTALL_NAMESPACE=${SUB_INSTALL_NAMESPACE}"
echo "DEBUG: SUB_PACKAGE=${SUB_PACKAGE}"
echo "DEBUG: SUB_CHANNEL=${SUB_CHANNEL}"

# Create the namespace if it doesn't exist
if ! oc get ns "${SUB_INSTALL_NAMESPACE}"; then
  echo "DEBUG: Creating namespace ${SUB_INSTALL_NAMESPACE}"
  oc create ns "${SUB_INSTALL_NAMESPACE}"
else
  echo "DEBUG: Namespace ${SUB_INSTALL_NAMESPACE} already exists"
fi

# Create the OperatorGroup
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

# Create the Subscription
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
  source: "${SUB_SOURCE:-"redhat-operators"}"
  sourceNamespace: "${SUB_SOURCE_NAMESPACE:-"openshift-marketplace"}"
EOF

echo "DEBUG: Checking catalog sources"
oc get catalogsource -n openshift-marketplace -o wide

echo "DEBUG: Waiting for operator deployment"
for i in $(seq 1 30); do
  echo "DEBUG: Attempt ${i}/30"
  
  echo "DEBUG: Checking subscription status"
  oc get subscription "${SUB_PACKAGE}" -n "${SUB_INSTALL_NAMESPACE}" -o yaml
  
  echo "DEBUG: Checking CSV status"
  csv=$(oc get subscription "${SUB_PACKAGE}" -n "${SUB_INSTALL_NAMESPACE}" -o jsonpath='{.status.currentCSV}' || echo "")
  if [ -n "${csv}" ]; then
    echo "DEBUG: Found CSV: ${csv}"
    oc get csv "${csv}" -n "${SUB_INSTALL_NAMESPACE}" -o yaml
  else
    echo "DEBUG: No CSV found yet"
  fi
  
  echo "DEBUG: Checking operator pods"
  oc get pods -n "${SUB_INSTALL_NAMESPACE}"
  
  if oc get subscription "${SUB_PACKAGE}" -n "${SUB_INSTALL_NAMESPACE}"; then
    if [[ "$(oc get subscription "${SUB_PACKAGE}" -n "${SUB_INSTALL_NAMESPACE}" -o jsonpath='{.status.state}')" == "AtLatestKnown" ]]; then
      echo "DEBUG: Operator successfully deployed"
      exit 0
    fi
  fi
  
  echo "DEBUG: Operator not ready yet. Waiting 30 seconds..."
  sleep 30
done

echo "ERROR: Operator deployment timeout"
echo "DEBUG: Final status check"
oc get subscription "${SUB_PACKAGE}" -n "${SUB_INSTALL_NAMESPACE}" -o yaml
oc get csv -n "${SUB_INSTALL_NAMESPACE}" -o yaml
oc get events -n "${SUB_INSTALL_NAMESPACE}"
oc get pods -n "${SUB_INSTALL_NAMESPACE}"

exit 1
