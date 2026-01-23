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

        # 1. Detailed OLM / Operator Subscription
        echo -e "=== OLM SUBSCRIPTION ANALYSIS ==="

        echo -e "\n>> Subscription Status:"
        if oc get subscription sailoperator -n openshift-operators -o yaml 2>/dev/null; then
            echo -e "\n>> Subscription Events:"
            oc get events -n openshift-operators --sort-by='.lastTimestamp' || true
        else
            echo "Subscription 'sailoperator' not found"
        fi

        echo -e "\n>> InstallPlan Details:"
        oc get installplan -n openshift-operators -o wide || true

        # Get detailed InstallPlan status
        local installplans
        installplans=$(oc get installplan -n openshift-operators --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
        for ip in $installplans; do
            if [[ -n "$ip" ]]; then
                echo -e "\n>> InstallPlan: $ip Status:"
                oc describe installplan "$ip" -n openshift-operators || true
            fi
        done

        echo -e "\n>> CSV (ClusterServiceVersion) Details:"
        oc get csv -n openshift-operators -o wide || true

        # Get detailed CSV status
        local csvs
        csvs=$(oc get csv -n openshift-operators --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -i sail || true)
        for csv in $csvs; do
            if [[ -n "$csv" ]]; then
                echo -e "\n>> CSV: $csv Status:"
                oc describe csv "$csv" -n openshift-operators || true
            fi
        done

        echo -e "\n>> All Deployments in openshift-operators:"
        oc get deployments -n openshift-operators -o wide || true

        echo -e "\n>> All Resources related to sailoperator:"
        oc get all -n openshift-operators -l operators.coreos.com/sailoperator.openshift-operators || true

        echo -e "\n>> Operator Hub / CatalogSource Status:"
        oc get catalogsource community-operators -n openshift-marketplace -o yaml || echo "Could not get community-operators catalogsource"

        echo -e "\n>> Package Manifest for sailoperator:"
        oc get packagemanifest sailoperator -o yaml || echo "Could not get sailoperator packagemanifest"

        # 2. Iterate through relevant namespaces
        echo -e "\n=== NAMESPACE ANALYSIS ==="
        local namespaces=("openshift-operators" "openshift-marketplace" "istio-system" "istio-cni" "ztunnel")
        for ns in "${namespaces[@]}"; do
            local ns_check_output
            if ns_check_output=$(oc get ns "$ns" 2>&1); then
                echo -e "\n--- [DEBUG] Namespace: $ns ---"

                echo ">> Pod Status:"
                oc get pods -n "$ns" -o wide || true

                echo ">> Recent Events (Sorted by Time, last 20):"
                oc get events -n "$ns" --sort-by='.lastTimestamp' | tail -n 20 || true

                # Identify, describe and get logs from all the pods in the namespace
                local pods
                pods=$(oc get pods -n "$ns" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)

                for pod in $pods; do
                    if [[ -n "$pod" ]]; then
                        echo -e "\n>> [DEBUG] Describing pod: $pod"
                        oc describe pod "$pod" -n "$ns" || true
                        echo ">> [DEBUG] Logs for $pod (last 100 lines):"
                        oc logs "$pod" -n "$ns" --all-containers --tail=100 --previous=false || echo "Could not retrieve current logs."
                        echo ">> [DEBUG] Previous logs for $pod (if any):"
                        oc logs "$pod" -n "$ns" --all-containers --tail=50 --previous=true 2>/dev/null || echo "No previous logs."
                    fi
                done

                # Check for any operator-related resources
                if [[ "$ns" == "openshift-operators" ]]; then
                    echo -e "\n>> Operator Resources in $ns:"
                    oc get all,configmap,secret -n "$ns" | grep -i sail || echo "No sail-related resources found"
                fi
            else
                echo -e "\n--- [DEBUG] Namespace: $ns (NOT FOUND) ---"
                echo ">> Namespace check failed: $ns_check_output"
            fi
        done

        # 3. Check Istio Custom Resources
        echo -e "\n=== ISTIO RESOURCES ANALYSIS ==="
        echo -e ">> Global Istio Resources State:"
        oc get istio,istiocni,ztunnel -A -o yaml 2>/dev/null || echo "No Istio custom resources found (expected if operator hasn't deployed yet)"

        # 4. Check cluster-wide operator status
        echo -e "\n=== CLUSTER OPERATOR STATUS ==="
        echo -e ">> Cluster Operators:"
        oc get co | grep -E "(NAME|operator-lifecycle-manager|marketplace)" || true

        echo -e "\n>> OLM Operator Pods:"
        oc get pods -n openshift-operator-lifecycle-manager || true

        echo -e "\n>> Marketplace Operator Pods:"
        oc get pods -n openshift-marketplace | grep -E "(NAME|catalog|packageserver)" || true

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

        # Provide intermediate status on every 5th attempt
        if [ $((attempt % 5)) -eq 0 ]; then
            echo "  >> Progress check at attempt $attempt:"
            case "$description" in
                *"InstallPlan"*)
                    echo "  >> Current InstallPlans:" && oc get installplan -n openshift-operators --no-headers 2>/dev/null || echo "  >> No InstallPlans found"
                    ;;
                *"CSV"*)
                    echo "  >> Current CSVs:" && oc get csv -n openshift-operators --no-headers 2>/dev/null || echo "  >> No CSVs found"
                    ;;
                *"deployment"*)
                    echo "  >> Current Deployments:" && oc get deployments -n openshift-operators --no-headers 2>/dev/null || echo "  >> No Deployments found"
                    echo "  >> Operator pods:" && oc get pods -n openshift-operators --no-headers 2>/dev/null || echo "  >> No pods found"
                    ;;
                *"istiod"*)
                    echo "  >> Istio pods:" && oc get pods -n istio-system --no-headers 2>/dev/null || echo "  >> No istio-system pods found"
                    ;;
                *)
                    echo "  >> Checking current state..."
                    eval "$command_to_run" 2>&1 || echo "  >> Command still failing"
                    ;;
            esac
        fi

        if [ "$attempt" -eq "$max_attempts" ]; then
            echo "ERROR: ${description} did not become available after $max_attempts attempts."
            echo "Final command output:"
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

# First, wait for the subscription to create an InstallPlan
echo "Step 1: Waiting for InstallPlan creation..."
retry_command "oc get installplan -n openshift-operators --no-headers | grep -q sailoperator" "InstallPlan creation for sailoperator"

# Check InstallPlan status
echo "Step 2: Waiting for InstallPlan approval and completion..."
retry_command "oc get installplan -n openshift-operators -o jsonpath='{.items[?(@.spec.clusterServiceVersionNames[*]==\"sailoperator*\")].status.phase}' | grep -q Installed" "InstallPlan completion"

# Wait for CSV to be created and ready
echo "Step 3: Waiting for ClusterServiceVersion (CSV) to be ready..."
retry_command "oc get csv -n openshift-operators --no-headers | grep sailoperator | grep -q Succeeded" "CSV to be ready"

# Now wait for the actual deployment - get the actual deployment name from the CSV
echo "Step 4: Identifying and waiting for operator deployment..."
OPERATOR_DEPLOYMENT=""
attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    # Get deployment name from CSV
    OPERATOR_DEPLOYMENT=$(oc get csv -n openshift-operators -o jsonpath='{.items[?(@.metadata.name=~"sailoperator.*")].spec.install.spec.deployments[0].name}' 2>/dev/null || true)

    if [ -n "$OPERATOR_DEPLOYMENT" ]; then
        echo "Found operator deployment: $OPERATOR_DEPLOYMENT"
        break
    fi

    echo "Waiting for deployment name from CSV... (attempt ${attempt}/${MAX_ATTEMPTS})"
    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
        echo "ERROR: Could not determine operator deployment name from CSV"
        echo "Available deployments in openshift-operators:"
        oc get deployments -n openshift-operators || true
        exit 1
    fi

    sleep "$SLEEP_DURATION"
    attempt=$((attempt + 1))
done

# Now wait for the actual deployment to be ready
echo "Step 5: Waiting for deployment $OPERATOR_DEPLOYMENT to be available..."
retry_command "oc wait --for=condition=Available=True --timeout=5s deployment/$OPERATOR_DEPLOYMENT -n openshift-operators" "$OPERATOR_DEPLOYMENT deployment"

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