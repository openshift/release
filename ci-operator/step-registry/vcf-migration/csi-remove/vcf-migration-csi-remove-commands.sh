#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function log() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

if [[ "${CSI_MANAGEMENT_REMOVED}" != "true" ]]; then
  log "CSI_MANAGEMENT_REMOVED is not true, skipping CSI driver patch"
  exit 0
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

log "patching vSphere CSI driver managementState to Removed"
oc patch clustercsidriver csi.vsphere.vmware.com --type=merge --patch '{"spec":{"managementState":"Removed"}}'

log "vSphere CSI driver management has been removed"
