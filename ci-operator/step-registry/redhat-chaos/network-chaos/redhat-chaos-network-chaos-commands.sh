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

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export ELASTIC_INDEX=krkn_chaos_ci

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config

export KUBECONFIG=/tmp/config
export DURATION=$DURATION
export NODE_NAME=$NODE_NAME
export LABEL_SELECTOR=$LABEL_SELECTOR
export INSTANCE_COUNT=$INSTANCE_COUNT
export INTERFACES=$INTERFACES
export EXECUTION=$EXECUTION
export EGRESS=$EGRESS
export KRKN_KUBE_CONFIG=$KUBECONFIG
export ENABLE_ALERTS=False
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password
export NETWORK_PARAMS=$NETWORK_PARAMS
export WAIT_DURATION=$WAIT_DURATION

./network-chaos/prow_run.sh
rc=$?
echo "Finished running network chaos"
echo "Return code: $rc"