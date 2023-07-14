#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export STORE_PATH="${ARTIFACT_DIR}/resource-watch-store"
export REPOSITORY_PATH="${ARTIFACT_DIR}/resource-watch-store/repo"

function cleanup() {
  local signal=$1
  echo "killing resource watch at $(date), signal=${signal}"
  CHILDREN=$(jobs -p)
  if test -n "${CHILDREN}"
  then
    kill ${CHILDREN} && wait
  fi

  echo "Artifact dir:"
  ls -l ${ARTIFACT_DIR}

  echo "repo dir"
  ls -l ${STORE_PATH}
  tar -czC $STORE_PATH -f "${ARTIFACT_DIR}/resource-watch-store.tar.gz" .

  echo "${signal}: ended resource watch gracefully"

  exit 0
}

# Make traps for each type of signal so we know what signal was trapped.
trap 'cleanup SIGINT' SIGINT
trap 'cleanup SIGTERM' SIGTERM
trap 'cleanup EXIT' EXIT

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

openshift-tests run-resourcewatch > "${ARTIFACT_DIR}/run-resourcewatch.log" 2>&1 &
resourcewatch_pid=$!
echo "Started openshift-tests run-resourcewatch with PID $resourcewatch_pid"

openshift-tests run-monitor --artifact-dir $STORE_PATH > "${ARTIFACT_DIR}/run-monitor.log" 2>&1 &
runmonitor_pid=$!
echo "Started openshift-tests run-monitor with PID $runmonitor_pid"

wait
