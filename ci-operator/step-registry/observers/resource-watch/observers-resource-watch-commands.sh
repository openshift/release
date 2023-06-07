#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export STORE_PATH="${ARTIFACT_DIR}/resource-watch-store"
export REPOSITORY_PATH="${ARTIFACT_DIR}/resource-watch-store/repo"

function cleanup() {
  echo "killing resource watch"
  CHILDREN=$(jobs -p)
  if test -n "${CHILDREN}"
  then
    kill ${CHILDREN} && wait
  fi

  tar -czC $STORE_PATH -f "${ARTIFACT_DIR}/resource-watch-store.tar.gz" .
  rm -rf $STORE_PATH

  echo "ended resource watch gracefully"

  exit 0
}
trap cleanup EXIT

# $KUBECONFIG could not be available when the observer first starts
echo "waiting for $KUBECONFIG or $KUBECONFIGMINIMAL to exist"
while [[ ! -s "$KUBECONFIG" && ! -s "$KUBECONFIGMINIMAL" ]]
do
  sleep 1
done
echo 'kubeconfig received!'

if ! [[ -s ${KUBECONFIG} ]]; then
  export KUBECONFIG="$KUBECONFIGMINIMAL"
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

openshift-tests run-resourcewatch --v=4 --kubeconfig $KUBECONFIG --namespace default > "${ARTIFACT_DIR}/run-resourcewatch.log" 2>&1 &
openshift-tests run-monitor --artifact-dir $STORE_PATH > "${ARTIFACT_DIR}/run-monitor.log" 2>&1 &
wait
