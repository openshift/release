#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version
pushd /tmp

ls -la /root/kraken
git clone https://github.com/redhat-chaos/krkn-hub.git
pushd krkn-hub/

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config

export KUBECONFIG=/tmp/config
export NAMESPACE=$NAMESPACE
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
export TARGET_NODE_AND_INTERFACE=$TARGET_NODE_AND_INTERFACE

./prow/pod-network-chaos/prow_run.sh
rc=$?
echo "Finished running pod-network chaos"
echo "Return code: $rc"