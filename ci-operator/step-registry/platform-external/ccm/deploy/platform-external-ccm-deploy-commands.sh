#!/bin/bash

#
# Deploy CCM (provider agnostic) manifests and collect the logs.
#

set -o nounset
set -o errexit
set -o pipefail

function turn_down() {
  touch /tmp/ccm.done
}
trap turn_down EXIT

export KUBECONFIG=${SHARED_DIR}/kubeconfig
test -f "${SHARED_DIR}/deploy.env" && source "${SHARED_DIR}/deploy.env"

source "${SHARED_DIR}/init-fn.sh" || true

log "Starting CCM setup"

log "Collecting current cluster state"

log "Infrastructure CR:"
oc get infrastructure -o yaml

log "Nodes:"
oc get nodes

log "Pods:"
oc get pods -A

if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED-}" != "yes" ]]; then
  log "Ignoring CCM Installation setup. PLATFORM_EXTERNAL_CCM_ENABLED!=yes [${PLATFORM_EXTERNAL_CCM_ENABLED}]"
  exit 0
fi

source ${SHARED_DIR}/ccm.env

function stream_logs() {
  log "[log-stream] Starting log streamer"
  oc logs ${CCM_RESOURCE} -n ${CCM_NAMESPACE} >> ${ARTIFACT_DIR}/logs-ccm.txt 2>&1
  log "[log-stream] Finish log streamer"
}

function watch_logs() {
  log "[watcher] Starting watcher"
  while true; do
    test -f /tmp/ccm.done && break

    log "[watcher] creating streamer..."
    stream_logs &
    PID_STREAM="$!"
    log "[watcher] waiting streamer..."

    test -f /tmp/ccm.done && break
    sleep 10
    kill -9 "${PID_STREAM}" || true
  done
  log "[watcher] done!"
}

log "Creating watcher"
watch_logs &
PID_WATCHER="$!"

log "Deploying Cloud Controller Manager"

while read -r manifest
do
  echo "Creating resource from manifest ${SHARED_DIR}/${manifest}";
  oc create -f "${SHARED_DIR}"/"${manifest}" || true
done <<< "$(cat "${SHARED_DIR}/deploy-ccm-manifests.txt")"

## What will be an standard method?
# For AWS:
#CCM_STATUS_KEY=.status.availableReplicas
# For OCI:
#CCM_STATUS_KEY=.status.numberAvailable
if [[ -z "${CCM_STATUS_KEY}" ]]; then
  export CCM_STATUS_KEY=.status.availableReplicas
fi
until  oc wait --for=jsonpath="{${CCM_STATUS_KEY}}"=${CCM_REPLICAS_COUNT} ${CCM_RESOURCE} -n ${CCM_NAMESPACE} --timeout=10m &> /dev/null
do
  log "Waiting for minimum replicas avaialble..."
  sleep 10
done

log "CCM Ready!"

oc get all -n ${CCM_NAMESPACE}

log "Collecting logs for CCM initialization - initial 30 seconds"
sleep 30
touch /tmp/ccm.done

log "Sent signal to finish watcher"
wait "$PID_WATCHER"

log "Watcher done!"

oc get all -n ${CCM_NAMESPACE}
