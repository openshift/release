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
export TARGET_NODE_AND_INTERFACE=$TARGET_NODE_AND_INTERFACE
export NETWORK_PARAMS=$NETWORK_PARAMS
export WAIT_DURATION=$WAIT_DURATION

./network-chaos/prow_run.sh
rc=$?
echo "Finished running network chaos"
echo "Return code: $rc"