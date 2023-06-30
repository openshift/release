#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace


pwd 
ls -la

whoami


ls -la /root

ls -la /root/cerberus

/root/cerberus/start_cerberus.py --help

while [ ! -f "${KUBECONFIG}" ]; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"
  sleep 10
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"


echo "kubeconfig loc $KUBECONFIG"

export CERBERUS_KUBECONFIG=$KUBECONFIG
export CERBERUS_WATCH_NAMESPACES="[^.*$]"
export CERBERUS_IGNORE_PODS="[^installer*,^kube-burner*,^redhat-operators*,^certified-operators*,^collect-profiles*]"



./cerberus/prow_run.sh
rc=$?
echo "Finished running cerberus scenarios"
echo "Return code: $rc"