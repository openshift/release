#!/bin/bash

set -o errexit
ls 

function cerberus_cleanup() {

  curl_status=$(curl -X GET http://0.0.0.0:8080 2>/dev/null || cat /tmp/cerberus_status 2>/dev/null)
  echo "killing cerberus observer"
  kill ${cerberus_pid}

  if [[ -z $curl_status ]]; then
    if [ ! -f "${KUBECONFIG}" ]; then
      # Setting status to true because kubeconfig never was set and cerberus didn't run
      curl_status=True
    else 
      curl_status=False
    fi
  fi
  date
  ls 
  oc get ns
  jobs -l
  
  oc cluster-info
  echo "ended resource watch gracefully"
  echo "Finished running cerberus scenarios"
  echo '{"cerberus": '$curl_status'}' >> test.json

  pods=$(oc get pods -n $TEST_NAMESPACE --no-headers 2>/dev/null)
  if [[ -n $pods ]]; then 

    CREATED_POD_NAME=$(oc get pods -n $TEST_NAMESPACE --no-headers | awk '{print $1}')

    oc cp -n $TEST_NAMESPACE test.json $CREATED_POD_NAME:/tmp/test.json 
    output=$(oc rsh -n $TEST_NAMESPACE $CREATED_POD_NAME cat /tmp/test.json)
    echo "pod rsh $output"
    status_bool=$(echo $output | grep '"cerberus":' | sed 's/.*: //; s/[{},]//g')

    echo "$status_bool staus bool "
  fi

  replaced_str=$(echo $curl_status | sed "s/True/0/g" | sed "s/False/1/g" )
  exit $((replaced_str))
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

set -o nounset
set -o pipefail
set -x
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