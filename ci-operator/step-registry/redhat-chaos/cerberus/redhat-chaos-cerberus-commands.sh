#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x
ls 

function cerberus_cleanup() {
  echo "killing cerberus observer"
  kill -15 ${cerberus_pid}

  replaced_str=$(less -XF /tmp/cerberus_status | sed "s/True/0/g" | sed "s/False/1/g" )
  date
  echo "ended resource watch gracefully"
  echo "Finished running cerberus scenarios"
  exit $replaced_str
  
}
trap cerberus_cleanup EXIT SIGTERM SIGINT

while [ ! -f "${KUBECONFIG}" ]; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"
  sleep 10
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"

echo "kubeconfig loc $KUBECONFIG"

export CERBERUS_KUBECONFIG=$KUBECONFIG
export CERBERUS_WATCH_NAMESPACES="[^.*$]"
export CERBERUS_IGNORE_PODS="[^installer*,^kube-burner*,^redhat-operators*,^certified-operators*,^collect-profiles*,^loki*]"

mkdir -p ${ARTIFACT_DIR}/cerberus

cerberus_logs=${ARTIFACT_DIR}/cerberus/cerberus_prow_logs.out

./cerberus/prow_run.sh > $cerberus_logs 2>&1 &
cerberus_pid="$!"

jobs

jobs -p
while [[ -z $(cat $cerberus_logs | grep "signal=terminated") ]]; do 
  echo "sleep wait for next iteration"
  sleep 10
  cat /tmp/cerberus_status
done