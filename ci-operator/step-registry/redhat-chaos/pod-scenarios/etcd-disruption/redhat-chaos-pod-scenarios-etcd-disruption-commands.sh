#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

oc config view

oc projects
python3 --version


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

./pod-scenarios/prow_run.sh
rc=$?
echo "Done running the test!" 

cat /tmp/*.log 

echo "Return code: $rc"
exit $rc
echo $ENABLE_ALERTS
