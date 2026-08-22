#!/bin/bash

set -euo pipefail

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

function collect_artifacts {
  set +e
  log "=== Collecting debug artifacts ==="

  # Adapter resources
  oc describe pods -n "${NAMESPACE}" > "${ARTIFACT_DIR}/adapter-pod-describe.txt" 2>&1 || true
  oc logs "deployment/${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --all-containers > "${ARTIFACT_DIR}/adapter-logs.txt" 2>&1 || true
  oc logs "deployment/${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --all-containers --previous > "${ARTIFACT_DIR}/adapter-logs-previous.txt" 2>&1 || true
  oc get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' > "${ARTIFACT_DIR}/adapter-events.txt" 2>&1 || true
  oc get all -n "${NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/adapter-resources.yaml" 2>&1 || true

  # AgenticRun CRs created during test
  oc get agenticruns -n "${NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/agenticruns.yaml" 2>&1 || true

  # Operator resources (if present)
  if [[ -n "${OPERATOR_NAMESPACE:-}" ]]; then
    oc describe pods -n "${OPERATOR_NAMESPACE}" > "${ARTIFACT_DIR}/operator-pod-describe.txt" 2>&1 || true
    oc logs -n "${OPERATOR_NAMESPACE}" -l app=lightspeed-agentic-operator --all-containers > "${ARTIFACT_DIR}/operator-logs.txt" 2>&1 || true
  fi

  log "=== Artifacts collected in ${ARTIFACT_DIR} ==="
  log "=== Total script duration: $((SECONDS / 60))m$((SECONDS % 60))s (${SECONDS}s) ==="
}

trap collect_artifacts EXIT

log "=== Lightspeed Agentic Alerts Adapter E2E ==="
log "IMAGE: ${IMAGE}"
log "NAMESPACE: ${NAMESPACE}"
log "DEPLOYMENT_NAME: ${DEPLOYMENT_NAME}"
log "OPERATOR_NAMESPACE: ${OPERATOR_NAMESPACE:-openshift-lightspeed}"

start_step "Installing prerequisites"
# Ensure oc and yq are available
if ! command -v oc &>/dev/null; then
  log "ERROR: oc command not found"
  exit 1
fi

if ! command -v yq &>/dev/null; then
  log "Installing yq..."
  YQ_VERSION="v4.40.5"
  YQ_BINARY="yq_linux_amd64"

  # Create private directory for binary
  YQ_DIR=$(mktemp -d)
  chmod 700 "${YQ_DIR}"

  # Download binary and checksums
  curl --fail --show-error --location \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" \
    -o "${YQ_DIR}/yq"
  curl --fail --show-error --location \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums" \
    -o "${YQ_DIR}/checksums"

  # Verify checksum
  (cd "${YQ_DIR}" && grep "${YQ_BINARY}" checksums | sha256sum --check --status) || {
    log "ERROR: yq checksum verification failed"
    rm -rf "${YQ_DIR}"
    exit 1
  }

  chmod +x "${YQ_DIR}/yq"
  export PATH="${YQ_DIR}:${PATH}"
  log "yq installed at ${YQ_DIR}/yq"
fi
end_step "Installing prerequisites"

start_step "Deploy adapter with make deploy-e2e"
# The deploy-e2e.sh script expects IMAGE env var and uses the defaults we set
make deploy-e2e
end_step "Deploy adapter with make deploy-e2e"

start_step "Run E2E test suite"
# Run the Ginkgo-based E2E test suite (30m timeout in Makefile)
make test-e2e
end_step "Run E2E test suite"

start_step "Cleanup with make undeploy-e2e"
make undeploy-e2e
end_step "Cleanup with make undeploy-e2e"

log "=== E2E test complete ==="
