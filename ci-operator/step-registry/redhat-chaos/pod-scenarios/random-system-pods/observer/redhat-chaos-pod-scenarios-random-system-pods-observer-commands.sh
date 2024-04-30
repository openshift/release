#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x
ls

krkn_start_file=${SHARED_DIR}/krkn_start.txt

while [ ! -f $krkn_start_file ] ; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${krkn_start_file}"
  sleep 3
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${krkn_start_file}"

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config

export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE 

./pod-scenarios/prow_run.sh
rc=$?
echo "Done running the test!" 
echo "Return code: $rc"
exit $rc
