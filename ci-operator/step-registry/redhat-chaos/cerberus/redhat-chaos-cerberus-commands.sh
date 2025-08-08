#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x
ls 

function cerberus_cleanup() {

  curl_status=$(curl -X GET http://0.0.0.0:8080)
  echo "killing cerberus observer"
  kill -15 ${cerberus_pid}
  
  # c_status=$(cat /tmp/cerberus_status)
  date
  ls 
  oc get ns

  oc get pods -n $TEST_NAMESPACE
  jobs -l

  oc cluster-info
  echo "ended resource watch gracefully"
  echo "Finished running cerberus scenarios"
  echo '{"cerberus": '$curl_status'}' >> test.json
  
  CREATED_POD_NAME=$(oc get pods -n $TEST_NAMESPACE --no-headers | awk '{print $1}')

  oc cp -n $TEST_NAMESPACE test.json $CREATED_POD_NAME:/tmp/test.json 
  output=$(oc rsh -n $TEST_NAMESPACE $CREATED_POD_NAME cat /tmp/test.json)
  echo "pod rsh $output"
  exit 0
}
trap cerberus_cleanup EXIT SIGTERM SIGINT

while [ ! -f "${KUBECONFIG}" ]; do
  sleep 10
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"

echo "kubeconfig loc $KUBECONFIG"

export CERBERUS_KUBECONFIG=$KUBECONFIG
export CERBERUS_WATCH_NAMESPACES="[^.*$]"
export CERBERUS_IGNORE_PODS="[^installer*,^kube-burner*,^redhat-operators*,^certified-operators*,^collect-profiles*,^loki*,^go*]"

mkdir -p ${ARTIFACT_DIR}/cerberus

cerberus_logs=${ARTIFACT_DIR}/cerberus/cerberus_prow_logs.out

./cerberus/prow_run.sh > $cerberus_logs 2>&1 &
cerberus_pid="$!"

jobs

jobs -p
while [[ -z $(cat $cerberus_logs | grep "signal=terminated") ]]; do 
  sleep 10
  date
done