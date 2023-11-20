#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

export KUBECONFIG=${SHARED_DIR}/kubeconfig

UP_COUNT=0

while true; do
  if [[ $UP_COUNT -ge 5 ]];
  then
    break;
  fi
  if oc get infrastructure >/dev/null; then
    UP_COUNT=$(( UP_COUNT + 1 ))
    echo_date "API UP [$UP_COUNT/5]"
    sleep 5
    continue
  fi
  echo_date "API DOWN, waiting 30s..."
  sleep 30
done

echo_date "API Healthy check done!"

echo_date "Dumping infrastructure object"
oc get infrastructure -o yaml
