#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function turn_down() {
  touch /tmp/ccm.done
}
trap turn_down EXIT

export KUBECONFIG=${SHARED_DIR}/kubeconfig

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

echo_date "Starting CCM setup"

echo_date "Collecting current cluster state"

echo_date "Infrastructure CR:"
oc get infrastructure -o yaml

echo_date "Nodes:"
oc get nodes

echo_date "Pods:"
oc get pods -A

if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED-}" != "yes" ]]; then
  echo_date "Ignoring CCM Installation setup. PLATFORM_EXTERNAL_CCM_ENABLED!=yes [${PLATFORM_EXTERNAL_CCM_ENABLED}]"
  exit 0
fi

export CCM_RESOURCE=$(<${SHARED_DIR}/CCM_RESOURCE)
export CCM_NAMESPACE=$(<${SHARED_DIR}/CCM_NAMESPACE)
export CCM_REPLICAS_COUNT=$(<${SHARED_DIR}/CCM_REPLICAS_COUNT)

function stream_logs() {
  echo_date "[log-stream] Starting log streamer"
  oc logs ${CCM_RESOURCE} -n ${CCM_NAMESPACE} >> ${ARTIFACT_DIR}/logs-ccm.txt 2>&1
  echo_date "[log-stream] Finish log streamer"
}

function watch_logs() {
  echo_date "[watcher] Starting watcher"
  while true; do
    test -f /tmp/ccm.done && break

    echo_date "[watcher] creating streamer..."
    stream_logs &
    PID_STREAM="$!"
    echo_date "[watcher] waiting streamer..."

    test -f /tmp/ccm.done && break
    sleep 10
    kill -9 "${PID_STREAM}" || true
  done
  echo_date "[watcher] done!"
}

echo_date "Creating watcher"
watch_logs &
PID_WATCHER="$!"

echo_date "Deploying Cloud Controller Manager"

while read -r manifest
do
  echo "Processing manifest $manifest";
  oc create -f $manifest
done <<< "$(cat "${SHARED_DIR}/ccm-manifests.txt")"

until  oc wait --for=jsonpath='{.status.availableReplicas}'=${CCM_REPLICAS_COUNT} ${CCM_RESOURCE} -n ${CCM_NAMESPACE} --timeout=10m &> /dev/null
do
  echo_date "Waiting for minimum replicas avaialble..."
  sleep 10
done

echo_date "CCM Ready!"

oc get all -n ${CCM_NAMESPACE}

echo_date "Collecting logs for CCM initialization - initial 30 seconds"
sleep 30
touch /tmp/ccm.done

echo_date "Sent signal to finish watcher"
wait "$PID_WATCHER"

echo_date "Watcher done!"

oc get all -n ${CCM_NAMESPACE}