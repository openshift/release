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

debug_on_failure() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n"
        echo "################################################################"
        echo "     DEBUG: Script failed with exit code ${exit_code}"
        echo "################################################################"
        
        # 1. Check OLM / Operator Subscription Status
        echo -e "Checking OLM Status (Subscriptions, InstallPlans, CSVs)..."
        oc get subscription,installplan,clusterserviceversion -n openshift-operators || true

        # 2. Iterate through relevant namespaces
        local namespaces=("openshift-operators" "istio-system" "istio-cni" "ztunnel")
        for ns in "${namespaces[@]}"; do
            local ns_check_output
            if ns_check_output=$(oc get ns "$ns" 2>&1); then
                echo -e "\n--- [DEBUG] Namespace: $ns ---"
                
                echo ">> Pod Status:"
                oc get pods -n "$ns" || true
                
                echo ">> Recent Events (Sorted by Time):"
                oc get events -n "$ns" --sort-by='.lastTimestamp' | tail -n 15 || true
                
                # Identify, describe and get logs from all the pods in the namespace
                local pods
                pods=$(oc get pods -n "$ns" --no-headers | awk '{print $2}' || true)
                
                for pod in $pods; do
                    echo -e "\n>> [DEBUG] Describing failing pod: $pod"
                    oc describe pod "$pod" -n "$ns" || true
                    echo ">> [DEBUG] Logs for $pod (last 50 lines):"
                    oc logs "$pod" -n "$ns" --all-containers --tail=50 || echo "Could not retrieve logs."
                done
            else
                echo -e "\n--- [DEBUG] Namespace: $ns (NOT FOUND) ---"
                echo ">> Namespace check failed: $ns_check_output"
            fi
        done

        # 3. Check Istio Custom Resources
        echo -e "\n>> [DEBUG] Global Istio Resources State:"
        oc get istio,istiocni,ztunnel -A -o yaml || true
        
        echo -e "\n################################################################"
    fi
}

# Register the trap to catch errors or early exits
trap debug_on_failure EXIT

retry_command() {
    local command_to_run="$1"
    local description="$2"
    local attempt=1
    local max_attempts=$MAX_ATTEMPTS
    local sleep_duration=$SLEEP_DURATION

    echo "Awaiting ${description} (Max ${max_attempts} attempts)"

    while [ "$attempt" -le "$max_attempts" ]; do
        if eval "$command_to_run" >/dev/null 2>&1; then
            echo "${description} is available."
            return 0
        fi

        echo "Waiting for ${description}... (attempt ${attempt}/${max_attempts})"

        if [ "$attempt" -eq "$max_attempts" ]; then
            echo "ERROR: ${description} did not become available after $max_attempts attempts."
            eval "$command_to_run" || true
            return 1
        fi
        
        sleep "$sleep_duration"
        attempt=$((attempt + 1))
    done
}

# --- Deploy Steps ---

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

echo "Awaiting sail-operator deployment (KUBECONFIG=${KUBECONFIG:-'not set'})"
retry_command "oc wait --for=condition=Available=True --timeout=5s deployment/sail-operator -n openshift-operators" "sail-operator deployment"

# Install the Istio control plane
if [ "${ISTIO_CONTROL_PLANE_MODE}" == "ambient" ]; then
    echo "Deploying Istio control plane in ambient mode"
    BUILD_WITH_CONTAINER=0 make deploy-istio-with-ambient
elif [ "${ISTIO_CONTROL_PLANE_MODE}" == "sidecar" ]; then
    echo "Deploying Istio control plane in sidecar mode"
    BUILD_WITH_CONTAINER=0 make deploy-istio-with-cni
else
    echo "ERROR: Unsupported mode: ${ISTIO_CONTROL_PLANE_MODE}. Use 'ambient' or 'sidecar'."
    exit 1
fi

echo "Verifying Istio control plane deployment"
retry_command "oc wait --for=condition=Available=True --timeout=5s deployment/istiod -n istio-system" "istiod deployment"

echo "Verifying Istio CNI DaemonSet"
retry_command "oc rollout status ds/istio-cni-node -n istio-cni --timeout=5s" "Istio CNI"

if [ "${ISTIO_CONTROL_PLANE_MODE}" == "ambient" ]; then
    echo "Verifying Ztunnel deployment"
    retry_command "oc rollout status ds/ztunnel -n ztunnel --timeout=5s" "Ztunnel"
fi

echo -e "\n--- FINAL STATUS ---"
oc get pods -A | grep -E "istio|sail|ztunnel" || true
oc get istio,istiocni,ztunnel -A || true

echo "Sail Operator and Istio control plane deployed successfully."

# Clear trap on success so we don't trigger debug output for a successful run
trap - EXIT