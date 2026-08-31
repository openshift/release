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
  oc describe pods -n "${ADAPTER_NAMESPACE}" > "${ARTIFACT_DIR}/adapter-pod-describe.txt" 2>&1 || true
  oc logs "deployment/${DEPLOYMENT_NAME}" -n "${ADAPTER_NAMESPACE}" --all-containers > "${ARTIFACT_DIR}/adapter-logs.txt" 2>&1 || true
  oc logs "deployment/${DEPLOYMENT_NAME}" -n "${ADAPTER_NAMESPACE}" --all-containers --previous > "${ARTIFACT_DIR}/adapter-logs-previous.txt" 2>&1 || true
  oc get events -n "${ADAPTER_NAMESPACE}" --sort-by='.lastTimestamp' > "${ARTIFACT_DIR}/adapter-events.txt" 2>&1 || true
  oc get all -n "${ADAPTER_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/adapter-resources.yaml" 2>&1 || true

  # AgenticRun CRs created during test
  oc get agenticruns -n "${ADAPTER_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/agenticruns.yaml" 2>&1 || true

  # Operator resources
  local op_ns="${OPERATOR_NAMESPACE:-openshift-lightspeed}"
  oc describe pods -n "${op_ns}" > "${ARTIFACT_DIR}/operator-pod-describe.txt" 2>&1 || true
  oc logs -n "${op_ns}" -l app=lightspeed-agentic-operator --all-containers > "${ARTIFACT_DIR}/operator-logs.txt" 2>&1 || true

  log "=== Artifacts collected in ${ARTIFACT_DIR} ==="
  log "=== Total script duration: $((SECONDS / 60))m$((SECONDS % 60))s (${SECONDS}s) ==="
}

trap collect_artifacts EXIT

log "=== Lightspeed Agentic Alerts Adapter E2E ==="
log "IMAGE: ${IMAGE}"
log "ADAPTER_NAMESPACE: ${ADAPTER_NAMESPACE}"
log "DEPLOYMENT_NAME: ${DEPLOYMENT_NAME}"
log "OPERATOR_NAMESPACE: ${OPERATOR_NAMESPACE}"

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
  # The checksums file uses a multi-hash format (see checksums_hashes_order);
  # SHA-256 is the 18th hash type, i.e. field 19 (field 1 is the filename).
  EXPECTED_SHA256=$(awk -v bin="${YQ_BINARY}" '$1 == bin {print $19}' "${YQ_DIR}/checksums")
  ACTUAL_SHA256=$(sha256sum "${YQ_DIR}/yq" | awk '{print $1}')
  if [[ -z "${EXPECTED_SHA256}" || "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
    log "ERROR: yq checksum verification failed (expected=${EXPECTED_SHA256:-not_found}, actual=${ACTUAL_SHA256})"
    rm -rf "${YQ_DIR}"
    exit 1
  fi

  chmod +x "${YQ_DIR}/yq"
  export PATH="${YQ_DIR}:${PATH}"
  log "yq installed at ${YQ_DIR}/yq"
fi
end_step "Installing prerequisites"

# The ci-operator src build may create a vendor/ directory that is out of sync
# with go.mod (stale vendor/modules.txt). Use -mod=mod to bypass vendor/ and
# resolve modules from the cache / network instead. This matches how the unit
# and lint jobs are configured in the CI config.
export GOFLAGS="${GOFLAGS:+${GOFLAGS} }-mod=mod"
export GOMODCACHE=/tmp/gomodcache
log "GOFLAGS=${GOFLAGS}"

# Export NAMESPACE for the upstream Makefile/scripts (hack/deploy-e2e.sh) which
# expect it. Note: we intentionally do NOT declare NAMESPACE in the ref's env
# list because it is a reserved ci-operator variable (the CI build namespace).
export NAMESPACE="${ADAPTER_NAMESPACE}"

start_step "Deploy adapter with make deploy-e2e"
make deploy-e2e
end_step "Deploy adapter with make deploy-e2e"

start_step "Run E2E test suite"
# Run the Ginkgo-based E2E test suite (30m timeout in Makefile)
make test-e2e
end_step "Run E2E test suite"

start_step "Cleanup"
# Delete adapter resources but skip the namespace object. The manifests/
# directory includes namespace.yaml whose deletion is synchronous — oc blocks
# until every resource in the namespace is fully terminated, which can hang for
# hours when the operator has finalizers. Since the cluster is returned to the
# pool after the job, the namespace doesn't need explicit cleanup.
# Use --wait=false so resource deletion returns immediately.
for f in manifests/*.yaml; do
  [[ "$(basename "$f")" == "namespace.yaml" ]] && continue
  oc delete --ignore-not-found --wait=false -f "$f" || true
done
end_step "Cleanup"

log "=== E2E test complete ==="
