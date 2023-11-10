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



./prow/time-scenarios/prow_run.sh
rc=$?
echo "Finished running time scenario"
echo "Return code: $rc"
