#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x
ls

ES_PASSWORD=$(cat "/secret/es/password" || "")
ES_USERNAME=$(cat "/secret/es/username" || "")

export ES_PASSWORD
export ES_USERNAME

if [[ -n $ES_PASSWORD ]]; then
    export ELASTIC_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
fi

telemetry_password=$(cat "/secret/telemetry/telemetry_password"  || "")
export TELEMETRY_PASSWORD=$telemetry_password

while [ ! -f "${KUBECONFIG}" ]; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"
  sleep 30
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"

echo "kubeconfig loc $KUBECONFIG"

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config

export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE 

while [ "$(oc get ns | grep -c 'start-kraken')" -lt 1 ]; do
  echo "start kraken not found yet, waiting"
  sleep 10
done

echo "starting pod scenarios"
./pod-scenarios/prow_run.sh

echo "Done running the test!" 

exit 0

