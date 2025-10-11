#!/bin/bash
set -o errexit

ES_PASSWORD=$(cat "/secret/es/password")
ES_USERNAME=$(cat "/secret/es/username")

export ES_PASSWORD
export ES_USERNAME

export ES_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config

export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE
export ENABLE_ALERTS=False
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password
console_url=$(oc get routes -n openshift-console console -o jsonpath='{.spec.host}')
export HEALTH_CHECK_URL=https://$console_url

set -o nounset
set -o pipefail
set -x

echo "=========================================="
echo "Pre-test diagnostics"
echo "=========================================="
echo "NODE_SELECTOR: ${NODE_SELECTOR}"
echo "NUMBER_OF_NODES: ${NUMBER_OF_NODES}"
echo "TARGET_NAMESPACE: ${TARGET_NAMESPACE}"

echo ""
echo "Checking worker nodes that match selector '${NODE_SELECTOR}':"
oc get nodes -l "${NODE_SELECTOR}" --no-headers

echo ""
echo "Worker node count:"
oc get nodes -l "${NODE_SELECTOR}" --no-headers | wc -l

echo ""
echo "Detailed node information:"
oc get nodes -l "${NODE_SELECTOR}" -o wide

echo ""
echo "Node CPU and Memory status:"
oc adm top nodes -l "${NODE_SELECTOR}" || echo "Warning: Could not get node metrics"

echo ""
echo "Checking for master/control-plane nodes (should NOT be targeted):"
oc get nodes -l node-role.kubernetes.io/master --no-headers || echo "No master nodes found"
oc get nodes -l node-role.kubernetes.io/control-plane --no-headers || echo "No control-plane nodes found"

echo ""
echo "=========================================="
echo "Starting memory-hog scenario"
echo "=========================================="

/usr/bin/id
ls -alh ./memory-hog/
./memory-hog/prow_run.sh
rc=$?

echo ""
echo "=========================================="
echo "Post-test diagnostics (rc=$rc)"
echo "=========================================="

# Capture pod information if the test failed
if [[ $rc -ne 0 ]]; then
    echo "Test failed with return code $rc - gathering diagnostic information"
    
    echo ""
    echo "Looking for memory-hog pods in namespace ${TARGET_NAMESPACE}:"
    oc get pods -n ${TARGET_NAMESPACE} -l scenario=memory-hog -o wide || echo "No memory-hog pods found with label"
    oc get pods -n ${TARGET_NAMESPACE} | grep -i "memory-hog" || echo "No memory-hog pods found by name"
    
    echo ""
    echo "Getting all pods in ${TARGET_NAMESPACE} namespace:"
    oc get pods -n ${TARGET_NAMESPACE} -o wide
    
    # Try to find and describe any memory-hog related pods
    for pod in $(oc get pods -n ${TARGET_NAMESPACE} -o name | grep -i "memory-hog" || true); do
        echo ""
        echo "=========================================="
        echo "Describing pod: $pod"
        echo "=========================================="
        oc describe -n ${TARGET_NAMESPACE} "$pod" || echo "Could not describe $pod"
        
        echo ""
        echo "=========================================="
        echo "Pod YAML:"
        echo "=========================================="
        oc get -n ${TARGET_NAMESPACE} "$pod" -o yaml || echo "Could not get pod YAML"
        
        echo ""
        echo "=========================================="
        echo "Logs from pod: $pod"
        echo "=========================================="
        oc logs -n ${TARGET_NAMESPACE} "$pod" --all-containers=true --previous || echo "No previous logs available"
        oc logs -n ${TARGET_NAMESPACE} "$pod" --all-containers=true || echo "No current logs available"
    done
    
    echo ""
    echo "Recent events in ${TARGET_NAMESPACE} namespace (last 100):"
    oc get events -n ${TARGET_NAMESPACE} --sort-by='.lastTimestamp' | tail -100 || echo "Could not get events"
fi

echo ""
echo "Final node CPU and Memory status:"
oc adm top nodes -l "${NODE_SELECTOR}" || echo "Warning: Could not get node metrics"

if [[ $TELEMETRY_EVENTS_BACKUP == "True" ]]; then
    cp /tmp/events.json ${ARTIFACT_DIR}/events.json
fi
echo "Finished running memory hog scenario"
echo "Return code: $rc"
