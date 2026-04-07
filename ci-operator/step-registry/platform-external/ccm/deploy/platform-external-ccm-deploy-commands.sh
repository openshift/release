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

## What will be a standard method?
# For AWS:
#CCM_STATUS_KEY=.status.availableReplicas
# For OCI:
#CCM_STATUS_KEY=.status.numberAvailable
if [[ -z "${CCM_STATUS_KEY}" ]]; then
  export CCM_STATUS_KEY=.status.availableReplicas
fi

# Configuration for intelligent wait loop with timeout and exponential backoff
CCM_DEPLOY_TIMEOUT_MINUTES=${CCM_DEPLOY_TIMEOUT_MINUTES:-25}
CCM_DEPLOY_DIAGNOSTIC_INTERVAL=${CCM_DEPLOY_DIAGNOSTIC_INTERVAL:-60}
CCM_DEPLOY_FAIL_FAST_IMAGE_PULL_THRESHOLD=${CCM_DEPLOY_FAIL_FAST_IMAGE_PULL_THRESHOLD:-3}

TIMEOUT_SECONDS=$((CCM_DEPLOY_TIMEOUT_MINUTES * 60))
START_TIME=$(date +%s)
ITERATION=0
CURRENT_WAIT=10
MAX_WAIT=120
BACKOFF_FACTOR=1.5
LAST_REPLICAS_COUNT=0
IMAGE_PULL_BACKOFF_COUNT=0
LAST_DIAGNOSTIC_TIME=$START_TIME
NO_PODS_ITERATIONS=0

# Create diagnostic directory
DIAGNOSTIC_DIR="${ARTIFACT_DIR}/ccm-deployment-diagnostics"
mkdir -p "${DIAGNOSTIC_DIR}"

# Verbose log file
VERBOSE_LOG="${ARTIFACT_DIR}/ccm-wait-summary.log"
touch "${VERBOSE_LOG}"

# Helper function: Get deployment status
function get_deployment_status() {
  local current_replicas
  current_replicas=$(oc get ${CCM_RESOURCE} -n ${CCM_NAMESPACE} -o jsonpath="{${CCM_STATUS_KEY}}" 2>/dev/null || echo "0")
  echo "${current_replicas}/${CCM_REPLICAS_COUNT}"
}

# Helper function: Get pod status summary
function get_pod_status_summary() {
  local pods_output
  pods_output=$(oc get pods -n ${CCM_NAMESPACE} --no-headers 2>/dev/null || echo "")

  if [ -z "$pods_output" ]; then
    echo "0 pods"
    return
  fi

  local running=$(echo "$pods_output" | grep -c "Running" || echo "0")
  local pending=$(echo "$pods_output" | grep -c "Pending" || echo "0")
  local container_creating=$(echo "$pods_output" | grep -c "ContainerCreating" || echo "0")
  local error=$(echo "$pods_output" | grep -cE "Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull" || echo "0")

  local summary=""
  [ "$running" -gt 0 ] && summary="${summary}${running} Running, "
  [ "$pending" -gt 0 ] && summary="${summary}${pending} Pending, "
  [ "$container_creating" -gt 0 ] && summary="${summary}${container_creating} ContainerCreating, "
  [ "$error" -gt 0 ] && summary="${summary}${error} Error, "

  summary=${summary%, }  # Remove trailing comma
  [ -z "$summary" ] && summary="Unknown status"

  echo "$summary"
}

# Helper function: Collect diagnostic snapshot
function collect_diagnostic_snapshot() {
  local iteration=$1
  local snapshot_dir="${DIAGNOSTIC_DIR}/iteration-$(printf "%03d" $iteration)"
  mkdir -p "${snapshot_dir}"

  oc get ${CCM_RESOURCE} -n ${CCM_NAMESPACE} -o yaml > "${snapshot_dir}/deployment.yaml" 2>&1 || true
  oc get pods -n ${CCM_NAMESPACE} -o yaml > "${snapshot_dir}/pods.yaml" 2>&1 || true
  oc describe pods -n ${CCM_NAMESPACE} > "${snapshot_dir}/pods-describe.txt" 2>&1 || true
  oc get events -n ${CCM_NAMESPACE} --sort-by='.lastTimestamp' > "${snapshot_dir}/events.txt" 2>&1 || true
  oc get replicasets -n ${CCM_NAMESPACE} -o yaml > "${snapshot_dir}/replicasets.yaml" 2>&1 || true
}

# Helper function: Perform fail-fast checks
function perform_fail_fast_checks() {
  local elapsed=$1

  # Check if deployment exists (fail after 2 minutes if not found)
  if [ $elapsed -gt 120 ]; then
    if ! oc get ${CCM_RESOURCE} -n ${CCM_NAMESPACE} &>/dev/null; then
      log "ERROR: Deployment ${CCM_RESOURCE} not found in namespace ${CCM_NAMESPACE} after 2 minutes"
      echo "ERROR: Deployment not found after 2 minutes" >> "${VERBOSE_LOG}"
      return 1
    fi
  fi

  # Check for no pods created (fail after 5 iterations)
  local pod_count=$(oc get pods -n ${CCM_NAMESPACE} --no-headers 2>/dev/null | wc -l)
  if [ "$pod_count" -eq 0 ]; then
    NO_PODS_ITERATIONS=$((NO_PODS_ITERATIONS + 1))
    if [ $NO_PODS_ITERATIONS -ge 5 ]; then
      log "ERROR: No pods created after 5 iterations (~50 seconds)"
      echo "ERROR: No pods created after 5 iterations" >> "${VERBOSE_LOG}"
      return 1
    fi
  else
    NO_PODS_ITERATIONS=0
  fi

  # Check for CrashLoopBackOff (fail immediately)
  if oc get pods -n ${CCM_NAMESPACE} -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -q "CrashLoopBackOff"; then
    log "ERROR: Pod in CrashLoopBackOff - indicates config/compatibility issue"
    echo "ERROR: CrashLoopBackOff detected" >> "${VERBOSE_LOG}"
    oc get pods -n ${CCM_NAMESPACE} >> "${VERBOSE_LOG}" 2>&1 || true
    return 1
  fi

  # Check for ImagePullBackOff (fail after 3 consecutive detections)
  if oc get pods -n ${CCM_NAMESPACE} -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null | grep -qE "ImagePullBackOff|ErrImagePull"; then
    IMAGE_PULL_BACKOFF_COUNT=$((IMAGE_PULL_BACKOFF_COUNT + 1))
    if [ $IMAGE_PULL_BACKOFF_COUNT -ge $CCM_DEPLOY_FAIL_FAST_IMAGE_PULL_THRESHOLD ]; then
      log "ERROR: ImagePullBackOff detected $IMAGE_PULL_BACKOFF_COUNT consecutive times"
      echo "ERROR: ImagePullBackOff threshold exceeded" >> "${VERBOSE_LOG}"
      oc get pods -n ${CCM_NAMESPACE} >> "${VERBOSE_LOG}" 2>&1 || true
      return 1
    fi
  else
    IMAGE_PULL_BACKOFF_COUNT=0
  fi

  return 0
}

# Helper function: Collect final diagnostics
function collect_final_diagnostics() {
  local reason=$1
  local final_dir="${ARTIFACT_DIR}/ccm-deployment-final-state"
  mkdir -p "${final_dir}"

  log "Collecting final diagnostics to ${final_dir}..."

  oc get ${CCM_RESOURCE} -n ${CCM_NAMESPACE} -o yaml > "${final_dir}/deployment.yaml" 2>&1 || true
  oc get pods -n ${CCM_NAMESPACE} -o yaml > "${final_dir}/pods.yaml" 2>&1 || true
  oc describe pods -n ${CCM_NAMESPACE} > "${final_dir}/pods-describe.txt" 2>&1 || true
  oc get events -n ${CCM_NAMESPACE} --sort-by='.lastTimestamp' > "${final_dir}/events.txt" 2>&1 || true
  oc get replicasets -n ${CCM_NAMESPACE} -o yaml > "${final_dir}/replicasets.yaml" 2>&1 || true
  oc get nodes -o yaml > "${final_dir}/nodes.yaml" 2>&1 || true

  # Create summary report
  cat > "${final_dir}/summary.txt" << EOF
CCM Deployment Failure Summary
==============================
Failure Reason: ${reason}
Elapsed Time: $(($(date +%s) - START_TIME)) seconds
Total Iterations: ${ITERATION}

Final Status:
$(oc get ${CCM_RESOURCE} -n ${CCM_NAMESPACE} 2>&1 || echo "Deployment not found")

Final Pods:
$(oc get pods -n ${CCM_NAMESPACE} 2>&1 || echo "No pods found")

Recent Events:
$(oc get events -n ${CCM_NAMESPACE} --sort-by='.lastTimestamp' | tail -20 2>&1 || echo "Could not fetch events")
EOF
}

log "Starting CCM deployment wait (timeout: ${CCM_DEPLOY_TIMEOUT_MINUTES}m)"
echo "$(date -u --rfc-3339=seconds) - Starting CCM deployment wait (timeout: ${CCM_DEPLOY_TIMEOUT_MINUTES}m)" >> "${VERBOSE_LOG}"

# Main wait loop with timeout, exponential backoff, and fail-fast checks
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))

  # Check overall timeout
  if [ $ELAPSED -ge $TIMEOUT_SECONDS ]; then
    log "TIMEOUT: CCM deployment failed to become ready within ${CCM_DEPLOY_TIMEOUT_MINUTES} minutes"
    echo "TIMEOUT: Exceeded ${CCM_DEPLOY_TIMEOUT_MINUTES} minutes" >> "${VERBOSE_LOG}"
    collect_final_diagnostics "Timeout after ${CCM_DEPLOY_TIMEOUT_MINUTES} minutes"
    exit 1
  fi

  ITERATION=$((ITERATION + 1))

  # Perform fail-fast checks
  if ! perform_fail_fast_checks $ELAPSED; then
    collect_final_diagnostics "Fail-fast check failed"
    exit 1
  fi

  # Get current replica count
  CURRENT_REPLICAS=$(oc get ${CCM_RESOURCE} -n ${CCM_NAMESPACE} -o jsonpath="{${CCM_STATUS_KEY}}" 2>/dev/null || echo "0")

  # Check if deployment is ready
  if [ "${CURRENT_REPLICAS}" -ge "${CCM_REPLICAS_COUNT}" ]; then
    log "CCM Ready! (took $(date -u -d @${ELAPSED} +%Mm%Ss))"
    echo "SUCCESS: CCM deployment ready after ${ELAPSED} seconds" >> "${VERBOSE_LOG}"
    break
  fi

  # Collect diagnostics periodically
  if [ $((CURRENT_TIME - LAST_DIAGNOSTIC_TIME)) -ge $CCM_DEPLOY_DIAGNOSTIC_INTERVAL ]; then
    collect_diagnostic_snapshot $ITERATION
    LAST_DIAGNOSTIC_TIME=$CURRENT_TIME
  fi

  # Get status summaries
  DEPLOYMENT_STATUS=$(get_deployment_status)
  POD_STATUS=$(get_pod_status_summary)

  # Calculate remaining time
  REMAINING=$((TIMEOUT_SECONDS - ELAPSED))
  REMAINING_MIN=$((REMAINING / 60))

  # Log to verbose file
  echo "$(date -u --rfc-3339=seconds) - [${ITERATION}] Deployment: ${DEPLOYMENT_STATUS} | Pods: ${POD_STATUS} | Next check: ${CURRENT_WAIT}s | Remaining: ${REMAINING_MIN}m" >> "${VERBOSE_LOG}"

  # Log to stdout (minute markers only to avoid clutter)
  if [ $((ELAPSED % 60)) -lt $CURRENT_WAIT ]; then
    log "[Minute $((ELAPSED / 60))] Deployment: ${DEPLOYMENT_STATUS} | Pods: ${POD_STATUS}"
  elif [ $ITERATION -eq 1 ]; then
    log "[1/~$((TIMEOUT_SECONDS / 15))] Deployment: ${DEPLOYMENT_STATUS} | Pods: ${POD_STATUS} | Next check: ${CURRENT_WAIT}s"
  fi

  # Check for progress (if replicas increased, reset backoff)
  if [ "$CURRENT_REPLICAS" -gt "$LAST_REPLICAS_COUNT" ]; then
    CURRENT_WAIT=10
    echo "Progress detected: replicas increased from ${LAST_REPLICAS_COUNT} to ${CURRENT_REPLICAS}, resetting backoff to 10s" >> "${VERBOSE_LOG}"
  else
    # Apply exponential backoff
    CURRENT_WAIT=$(awk "BEGIN {print int($CURRENT_WAIT * $BACKOFF_FACTOR)}")
    if [ $CURRENT_WAIT -gt $MAX_WAIT ]; then
      CURRENT_WAIT=$MAX_WAIT
    fi
  fi

  LAST_REPLICAS_COUNT=$CURRENT_REPLICAS

  sleep $CURRENT_WAIT
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
