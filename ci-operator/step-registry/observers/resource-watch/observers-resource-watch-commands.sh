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

  if [ -f "${STORE_PATH}/e2e-events.json" ]; then
    cp "${STORE_PATH}/e2e-events.json" "${ARTIFACT_DIR}/e2e-events-observer.json"
  fi

  tar -czC $STORE_PATH -f "${ARTIFACT_DIR}/resource-watch-store.tar.gz" .
  rm -rf $STORE_PATH

  echo "ended resource watch gracefully"

  exit 0
}
trap cleanup INT TERM

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
  echo "using proxy from ${SHARED_DIR}/proxy-conf.sh"
fi

# Due to entrypoint-wrapper replacing the SHARED_DIR with a different value,
# use KUBECONFIGMINIMAL which is part of that SHARED_DIR and is not replaced.
DS_VARS=$(dirname ${KUBECONFIGMINIMAL})/ds-vars.conf
if test -f "${DS_VARS}"
then
  # shellcheck disable=SC1090
  source "${DS_VARS}"
  DEVSCRIPTS_TEST_IMAGE_REPO=${DS_REGISTRY}/localimages/local-test-image
  MONITOR_ARGS="--from-repository ${DEVSCRIPTS_TEST_IMAGE_REPO}"
  echo "using additional run-monitor args ${MONITOR_ARGS}"
fi

openshift-tests run-resourcewatch > "${ARTIFACT_DIR}/run-resourcewatch.log" 2>&1 &
DISABLED_MONITOR_TESTS="apiserver-new-disruption-invariant,disruption-summary-serializer,incluster-disruption-serializer,pod-network-avalibility"
openshift-tests run-monitor ${MONITOR_ARGS:-} --artifact-dir $STORE_PATH --disable-monitor=${DISABLED_MONITOR_TESTS} > "${ARTIFACT_DIR}/run-monitor.log" 2>&1 &
wait
