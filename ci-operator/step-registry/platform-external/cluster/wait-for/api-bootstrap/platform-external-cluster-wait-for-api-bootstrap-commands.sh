#!/bin/bash

#
# Wait for the Kube API is available on bootstrap node.
#

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/init-fn.sh" || true

# Set up the traps
trap collect_bootstrap_error_handler TERM INT HUP
trap collect_bootstrap_error_handler EXIT

install_oc

# Wait for API to become available with timeout
MAX_ATTEMPTS=60  # 30 minutes max (60 * 30s)
ATTEMPT=0
UP_COUNT=0
REQUIRED_UP_COUNT=5

log "Waiting for Kubernetes API to become available..."
while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
  if [[ $UP_COUNT -ge $REQUIRED_UP_COUNT ]]; then
    log "API is stable after $REQUIRED_UP_COUNT consecutive successful checks"
    break
  fi

  if oc get infrastructure >/dev/null 2>/dev/null; then
    UP_COUNT=$(( UP_COUNT + 1 ))
    log "API UP [$UP_COUNT/$REQUIRED_UP_COUNT]"
    sleep 5
  else
    UP_COUNT=0
    ATTEMPT=$(( ATTEMPT + 1 ))
    log "API DOWN, waiting 30s... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
    sleep 30
  fi
done

# Check if we timed out
if [[ $UP_COUNT -lt $REQUIRED_UP_COUNT ]]; then
  log "ERROR: Timed out waiting for API to become available after $MAX_ATTEMPTS attempts"
  exit 1
fi

log "API Healthy check done!"

log "Dumping infrastructure object:"
oc get infrastructure -o yaml
