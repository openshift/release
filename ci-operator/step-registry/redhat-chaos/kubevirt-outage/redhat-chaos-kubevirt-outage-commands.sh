#!/bin/bash
set -o errexit

console_url=$(oc get routes -n openshift-console console -o jsonpath='{.spec.host}')
export HEALTH_CHECK_URL=https://$console_url
oc get vmis -A
set -o nounset
set -o pipefail
set -x


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
export ENABLE_ALERTS=False
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password

export NAMESPACE=$TARGET_NAMESPACE 

# Wait up to 3 minutes for VMIs to appear in the namespace
echo "Waiting for VMIs to appear in namespace $NAMESPACE..."
timeout=300  # 5 minutes in seconds
interval=20   # Check every 20 seconds
elapsed=0
found=false

while [ $elapsed -lt $timeout ]; do
    if oc get vmi -A --no-headers 2>/dev/null | grep -q .; then
        echo "VMIs found"
        oc get vmi -A
        found=true
        break
    fi
    echo "Waiting for VMIs... (${elapsed}s/${timeout}s)"
    sleep $interval
    elapsed=$((elapsed + interval))
    date
done

if [ "$found" = false ]; then
    echo "Timeout: No VMIs found in namespace $NAMESPACE after 5 minutes"
    exit 1
fi

export KUBE_VIRT_NAMESPACE=$TARGET_NAMESPACE
./kubevirt-outage/prow_run.sh || rc=$?
rc=$?
if [[ $TELEMETRY_EVENTS_BACKUP == "True" ]]; then
    cp /tmp/events.json ${ARTIFACT_DIR}/events.json
fi
echo "Finished running kubevirt outage chaos disruption"
echo "Return code: $rc"
