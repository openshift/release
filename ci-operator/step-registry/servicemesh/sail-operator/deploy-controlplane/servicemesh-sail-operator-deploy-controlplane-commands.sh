#!/bin/bash

# ==============================================================================
# Sail Operator Deploy control plane deploys the Sail Operator from the current
# branch and code, and the Istio control plane with the specified mode: sidecar
# or ambient.
# ==============================================================================

set -o nounset
set -o errexit
set -o pipefail

MAX_ATTEMPTS=30
SLEEP_DURATION=10

retry_command() {
    local command_to_run="$1"
    local description="$2"
    local attempt=1
    local max_attempts=$MAX_ATTEMPTS
    local sleep_duration=$SLEEP_DURATION

    echo "Awaiting ${description} (Max ${max_attempts} attempts)"

    while [ "$attempt" -le "$max_attempts" ]; do
        if eval "$command_to_run" 2>/dev/null; then
            echo "${description} is available."
            return 0
        fi

        echo "Waiting for ${description} to be available... (attempt ${attempt}/${max_attempts})"

        if [ "$attempt" -eq "$max_attempts" ]; then
            echo "ERROR: ${description} did not become available after $max_attempts attempts ($((max_attempts * sleep_duration)) seconds)"
            # Execute the command one last time without suppressing error for diagnosis
            eval "$command_to_run" 
            return 1
        fi
        
        sleep "$sleep_duration"
        attempt=$((attempt + 1))
    done
}


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
retry_command "oc wait --for=condition=Available=True --timeout=1s deployment/sail-operator -n openshift-operators" "sail-operator deployment"

# Catch any errors during sail-operator deployment wait
if [ $? -ne 0 ]; then
    oc get pods -n openshift-operators
    oc get deployment sail-operator -n openshift-operators
    exit 1
fi

# Install the Istio control plane in the specified mode
if [ "${ISTIO_CONTROL_PLANE_MODE}" == "ambient" ]; then
    echo "Deploying Istio control plane in ambient mode"
    BUILD_WITH_CONTAINER=0 make deploy-istio-with-ambient
elif [ "${ISTIO_CONTROL_PLANE_MODE}" == "sidecar" ]; then
    echo "Deploying Istio control plane in sidecar mode"
    BUILD_WITH_CONTAINER=0 make deploy-istio-with-cni
else
    echo "ERROR: Unsupported ISTIO_CONTROL_PLANE_MODE=${ISTIO_CONTROL_PLANE_MODE}. Supported modes are: ambient, sidecar"
    exit 1
fi

echo "Verifying Istio control plane deployment"
retry_command "oc wait --for=condition=Available=True --timeout=1s deployment/istiod -n istio-system" "istiod deployment"
if [ $? -ne 0 ]; then
    oc get pods -n istio-system
    oc get deployment istiod -n istio-system
    exit 1
fi

echo "Verifying Istio CNI DaemonSet deployment"
retry_command "oc rollout status ds/istio-cni-node -n istio-cni --request-timeout=1s" "Istio CNI DaemonSet"
if [ $? -ne 0 ]; then
    oc get pods -n istio-cni
    oc get ds istio-cni-node -n istio-cni
    exit 1
fi

if [ "${ISTIO_CONTROL_PLANE_MODE}" == "ambient" ]; then
    echo "Verifying Ztunnel deployment"
    retry_command "oc rollout status ds/ztunnel -n ztunnel --request-timeout=1s" "Ztunnel DaemonSet"
    if [ $? -ne 0 ]; then
        oc get pods -n ztunnel
        oc get ds ztunnel -n ztunnel
        exit 1
    fi
fi

# Adding validation for DEBUG pourpose: list all pods and istio components
echo "Listing all pods in all namespaces:"
oc get pods --all-namespaces
oc get istio
oc get istiocni
oc get ztunnel

echo "Sail Operator and Istio control plane deployed successfully."