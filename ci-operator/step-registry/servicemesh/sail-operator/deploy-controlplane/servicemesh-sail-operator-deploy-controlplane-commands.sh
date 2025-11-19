#!/bin/bash

# ==============================================================================
# Sail Operator Deploy control plane deploys the Sail Operator from the current
# branch and code, and the Istio control plane with the specified mode: sidecar
# or ambient.
# ==============================================================================

set -o nounset
set -o errexit
set -o pipefail

# Install the Sail operator creating a Subscription to the specified channel
echo "Creating subscription file for sail-operator"
cat <<EOF > sail-operator-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sailoperator
  namespace: openshift-operators
spec:
  channel: "${SAIL_OPERATOR_CHANNEL}"
  installPlanApproval: Automatic
  name: sailoperator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Applying subscription file for sail-operator"
oc apply -f sail-operator-subscription.yaml
echo "Awaiting sail-operator deployment on (KUBECONFIG=${KUBECONFIG})"
MAX_ATTEMPTS=10
SLEEP_DURATION=10

for i in $(seq 1 $MAX_ATTEMPTS); do
    if oc wait --for=condition=Available=True --timeout=1s deployment/sail-operator -n openshift-operators 2>/dev/null; then
        echo "sail-operator deployment is available"
        break
    fi
    
    echo "Waiting for sail-operator deployment to be available... (attempt ${i}/${MAX_ATTEMPTS})"
    
    if [ $i -eq $MAX_ATTEMPTS ]; then
        echo "ERROR: sail-operator deployment did not become available after $((MAX_ATTEMPTS * SLEEP_DURATION)) seconds"
        oc get pods -n openshift-operators
        oc get deployment sail-operator -n openshift-operators
        exit 1
    fi
    
    sleep $SLEEP_DURATION
done


# Install the Istio control plane in the specified mode
if [ "${ISTIO_CONTROL_PLANE_MODE}" == "ambient" ]; then
    echo "Deploying Istio control plane in ambient mode"
    make deploy-istio-with-ambient
elif [ "${ISTIO_CONTROL_PLANE_MODE}" == "sidecar" ]; then
    echo "Deploying Istio control plane in sidecar mode"
    make deploy-istio-with-cni
else
    echo "ERROR: Unsupported ISTIO_CONTROL_PLANE_MODE=${ISTIO_CONTROL_PLANE_MODE}. Supported modes are: ambient, sidecar"
    exit 1
fi

# DEBUG: List all pods in all namespaces
echo "Listing all pods in all namespaces:"
oc get pods --all-namespaces
oc get istio
oc get istiocni

echo "Sail Operator and Istio control plane deployed successfully."
