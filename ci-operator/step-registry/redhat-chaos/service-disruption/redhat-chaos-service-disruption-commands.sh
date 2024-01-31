#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

oc config view

oc projects
python3 --version

ls -la /root/kraken

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config

export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE 
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password

oc get nodes --kubeconfig $KRKN_KUBE_CONFIG

echo $ENABLE_ALERTS
./namespace-scenarios/prow_run.sh
rc=$?
echo "Done running the test!" 
echo "Return code: $rc"
exit $rc
echo $ENABLE_ALERTS
