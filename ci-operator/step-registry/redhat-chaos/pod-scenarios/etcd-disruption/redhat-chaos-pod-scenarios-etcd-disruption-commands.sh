#!/bin/bash
set -o errexit

ES_PASSWORD=$(cat "/secret/es/password")
ES_USERNAME=$(cat "/secret/es/username")

export ES_PASSWORD
export ES_USERNAME

if [[ -n $ES_PASSWORD ]]; then
    export ES_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
fi

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config

export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE 
export ALERTS_PATH="/home/krkn/kraken/config/alerts_openshift.yaml"
telemetry_password=$(cat "/secret/telemetry/telemetry_password"  || "")
export TELEMETRY_PASSWORD=$telemetry_password

oc get nodes --kubeconfig $KRKN_KUBE_CONFIG
console_url=$(oc get routes -n openshift-console console -o jsonpath='{.spec.host}')
export HEALTH_CHECK_URL=https://$console_url

# Label ovnkube-node pods on worker nodes for targeted chaos testing
echo "Labeling ovnkube-node pods on worker nodes for targeted chaos testing..."

# Get worker node names
worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}')

# Get the namespace and pod names for ovnkube-node pods on worker nodes
for node in $worker_nodes; do
  oc get pods -A -l app=ovnkube-node -o wide | grep "$node" | while read namespace name ready status restarts age ip node rest; do
    echo "Labeling pod $name in namespace $namespace (on worker node $node) as ovnkube-node-worker"
    oc label pod $name -n $namespace ovnkube-node-worker=true --overwrite
  done
done

echo "Finished labeling ovnkube-node pods on worker nodes"

set -o nounset
set -o pipefail
set -x

./pod-scenarios/prow_run.sh
rc=$?
echo "Done running the test!" 

cat /tmp/*.log 
if [[ $TELEMETRY_EVENTS_BACKUP == "True" ]]; then
    cp /tmp/events.json ${ARTIFACT_DIR}/events.json
fi

echo "Return code: $rc"
exit $rc
