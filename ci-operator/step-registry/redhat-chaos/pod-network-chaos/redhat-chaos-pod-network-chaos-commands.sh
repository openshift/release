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

export ES_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config

export KUBECONFIG=/tmp/config
export NAMESPACE=$TEST_NAMESPACE
export TRAFFIC_TYPE=$TRAFFIC_TYPE
export INGRESS_PORTS=$INGRESS_PORTS
export EGRESS_PORTS=$EGRESS_PORTS
export LABEL_SELECTOR=$LABEL_SELECTOR
export INSTANCE_COUNT=$INSTANCE_COUNT
export WAIT_DURATION=$WAIT_DURATION
export TEST_DURATION=$TEST_DURATION

export KRKN_KUBE_CONFIG=$KUBECONFIG
export ENABLE_ALERTS=False
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password

./pod-network-chaos/prow_run.sh
rc=$?
echo "Finished running pod-network chaos"
echo "Return code: $rc"