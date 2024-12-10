#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version
ls


ES_USERNAME=$(cat "/secret/es/username")
ES_PASSWORD=$(cat "/secret/es/password")

export ES_USERNAME
export ES_PASSWORD

export ES_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"


echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password

export KUBECONFIG=/tmp/config
export ACTION=$ACTION
export OBJECT_TYPE=$OBJECT_TYPE     
export NAMESPACE=$TARGET_NAMESPACE
export CONTAINER_NAME=$CONTAINER_NAME
export LABEL_SELECTOR=$LABEL_SELECTOR
export KRKN_KUBE_CONFIG=$KUBECONFIG
export ENABLE_ALERTS=False

oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- curl -s   'http://localhost:9090/api/v1/alerts' | jq '.data.alerts[] | select(.labels.severity=="critical")| select(.state=="firing") | [.labels.alertname, .activeAt, .annotations.description]'

ls
pwd 

./time-scenarios/prow_run.sh
rc=$?

oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- curl -s   'http://localhost:9090/api/v1/alerts' | jq '.data.alerts[] | select(.labels.severity=="critical")| select(.state=="firing") | [.labels.alertname, .activeAt, .annotations.description]'

echo "Finished running time scenario"
echo "Return code: $rc"
