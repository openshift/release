#!/bin/bash

set -euo pipefail

PROXY_PID=""
STEP_SECONDS=0

function log {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [+$((SECONDS / 60))m$((SECONDS % 60))s] $*"
}

function start_step {
  STEP_SECONDS=$SECONDS
  log "=== START: $* ==="
}

function end_step {
  local step_duration=$((SECONDS - STEP_SECONDS))
  log "=== END: $* (took $((step_duration / 60))m$((step_duration % 60))s) ==="
}

function start_proxy {
  make proxy > "${ARTIFACT_DIR}/proxy.log" 2>&1 &
  PROXY_PID=$!
  # Wait until proxy is listening on port 9090 (max 10 attempts, 2s apart)
  for i in $(seq 1 10); do
    sleep 2
    kill -0 "$PROXY_PID" 2>/dev/null || { log "ERROR: Proxy died"; cat "${ARTIFACT_DIR}/proxy.log" || true; exit 1; }
    nc -z localhost 9090 2>/dev/null && break
    [[ $i -eq 10 ]] && { log "ERROR: Proxy not responding"; cat "${ARTIFACT_DIR}/proxy.log" || true; exit 1; }
  done
  log "Proxy ready (PID: $PROXY_PID)"
}

function stop_proxy {
  if [[ -n "$PROXY_PID" ]] && kill -0 "$PROXY_PID" 2>/dev/null; then
    log "Stopping proxy (PID: $PROXY_PID)..."
    kill -TERM "$PROXY_PID" 2>/dev/null || true
    # Wait up to 10s for graceful shutdown, then SIGKILL
    for i in $(seq 1 10); do kill -0 "$PROXY_PID" 2>/dev/null || break; sleep 1; done
    kill -0 "$PROXY_PID" 2>/dev/null && kill -KILL "$PROXY_PID" 2>/dev/null || true
  fi
}

function collect_artifacts {
  set +e  # Ensure cleanup completes even if commands fail
  
  log "=== Cleanup started ==="
  stop_proxy
  
  log "=== Collecting debug artifacts ==="
  oc describe pods -n "${CHA_NAMESPACE}" > "${ARTIFACT_DIR}/pod-describe.txt" 2>&1 || true
  oc logs "deployment/${CHA_DEPLOYMENT_NAME}" -n "${CHA_NAMESPACE}" --all-containers > "${ARTIFACT_DIR}/pod-logs.txt" 2>&1 || true
  oc logs "deployment/${CHA_DEPLOYMENT_NAME}" -n "${CHA_NAMESPACE}" --all-containers --previous > "${ARTIFACT_DIR}/pod-logs-previous.txt" 2>&1 || true
  oc get events -n "${CHA_NAMESPACE}" --sort-by='.lastTimestamp' > "${ARTIFACT_DIR}/events.txt" 2>&1 || true
  oc get deployment -n "${CHA_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/deployment.yaml" 2>&1 || true
  oc get all -n "${CHA_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/all-resources.yaml" 2>&1 || true
  
  log "=== Artifacts collected in ${ARTIFACT_DIR} ==="
  log "=== Total script duration: $((SECONDS / 60))m$((SECONDS % 60))s (${SECONDS}s) ==="
}

trap collect_artifacts EXIT

log "=== Cluster Health Analyzer Deployment ==="
log "CHA_IMAGE: ${CHA_IMAGE}"
log "CHA_MANIFESTS_PATH: ${CHA_MANIFESTS_PATH}"
log "CHA_DEPLOYMENT_NAME: ${CHA_DEPLOYMENT_NAME}"
log "CHA_NAMESPACE: ${CHA_NAMESPACE}"

# Rename to match what make targets expect
export NAMESPACE="${CHA_NAMESPACE}"
export MANIFESTS_PATH="${CHA_MANIFESTS_PATH}"
export DEPLOYMENT_NAME="${CHA_DEPLOYMENT_NAME}"

start_step "Installing dependencies"
make install-integration-test-tools
export PATH="/tmp:${PATH}"
end_step "Installing dependencies"

log "=== Running make targets ==="

start_step "Starting thanos proxy"
start_proxy
end_step "Starting thanos proxy"

start_step "undeploy-integration"
make undeploy-integration
end_step "undeploy-integration"

start_step "deploy-integration"
make deploy-integration
end_step "deploy-integration"

start_step "test-integration"
make test-integration
end_step "test-integration"

log "=== Deployment successful ==="
