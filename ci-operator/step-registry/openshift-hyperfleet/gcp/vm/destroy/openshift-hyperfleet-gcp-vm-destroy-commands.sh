#!/bin/bash

set -euo pipefail

HYPERFLEET_E2E_CREDENTIALS_PATH="/var/run/hyperfleet-e2e/"
export GOOGLE_APPLICATION_CREDENTIALS="${HYPERFLEET_E2E_CREDENTIALS_PATH}/hcm-hyperfleet-e2e.json"

log() {
    echo "$(date -u --rfc-3339=seconds) ${*}"
}

if [[ ! -f "${SHARED_DIR}/gcp_vm_name" ]]; then
  log "No VM name in ${SHARED_DIR}; create step did not run or failed early. Skipping cleanup."
  exit 0
fi

VM_NAME="$(cat "${SHARED_DIR}/gcp_vm_name")"
VM_ZONE="$(cat "${SHARED_DIR}/gcp_vm_zone")"
FIREWALL_RULE="$(cat "${SHARED_DIR}/gcp_vm_firewall_rule")"

# Install gcloud if it is not present in the step image.
function gcloud_install() {
  if ! which gcloud; then
    local tarball="google-cloud-cli-linux-x86_64.tar.gz"
    log "gcloud not installed, installing from https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${tarball}"
    pushd "${HOME}"
    curl -sSLO "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${tarball}"
    tar -xzf "${tarball}"
    export PATH="${HOME}/google-cloud-sdk/bin:${PATH}"
    popd
  fi
}

gcloud_install
gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"
PROJECT_ID="$(jq -r -c .project_id "${GOOGLE_APPLICATION_CREDENTIALS}")"
gcloud config set project "${PROJECT_ID}"

log "Deleting firewall rule ${FIREWALL_RULE}"
gcloud compute firewall-rules delete "${FIREWALL_RULE}" --quiet || \
  log "WARNING: failed to delete firewall rule ${FIREWALL_RULE}"

log "Deleting VM ${VM_NAME} in ${VM_ZONE}"
gcloud compute instances delete "${VM_NAME}" --zone="${VM_ZONE}" --quiet || \
  log "WARNING: failed to delete VM ${VM_NAME}"

log "Cleanup complete"
