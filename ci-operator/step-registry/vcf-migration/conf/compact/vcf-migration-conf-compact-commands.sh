#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function log() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

if [[ ! -f "${SHARED_DIR}/install-config.yaml" ]]; then
  log "install-config.yaml not found"
  exit 1
fi

log "modifying install-config for compact cluster (0 workers)"

# Set compute replicas to 0 for compact cluster
yq -i '.compute[0].replicas = 0' "${SHARED_DIR}/install-config.yaml"

log "install-config modified for compact cluster"
cat "${SHARED_DIR}/install-config.yaml"
