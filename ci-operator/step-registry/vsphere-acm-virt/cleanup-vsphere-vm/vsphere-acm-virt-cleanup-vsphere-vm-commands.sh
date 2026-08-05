#!/bin/bash
#
# Clean up vSphere source VM created for MTV cold migration testing.
# Runs as best_effort — errors are logged but do not fail the job.
#
set -euxo pipefail

if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# --------------------------------------------------------------------------
# Load govc environment (credentials — tracing disabled)
# --------------------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/govc-env.sh" ]]; then
    echo "No govc-env.sh found in SHARED_DIR — nothing to clean up"
    exit 0
fi

_was_tracing=false
[[ $- == *x* ]] && _was_tracing=true
set +x
# shellcheck disable=SC1090
source "${SHARED_DIR}/govc-env.sh"
$_was_tracing && set -x

# TLS CA certs (optional — re-mount from credentials)
CREDS_DIR="/var/run/vsphere-credentials"
if [[ -f "${CREDS_DIR}/cacert" ]]; then
    export GOVC_TLS_CA_CERTS="${CREDS_DIR}/cacert"
fi

# --------------------------------------------------------------------------
# Read VM name
# --------------------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/vsphere-source-vm.json" ]]; then
    echo "No vsphere-source-vm.json found — nothing to clean up"
    exit 0
fi

VM_NAME="$(jq -r '.vm_name' "${SHARED_DIR}/vsphere-source-vm.json")"
if [[ -z "${VM_NAME}" || "${VM_NAME}" == "null" ]]; then
    echo "No VM name found in metadata — nothing to clean up"
    exit 0
fi

echo "=== Cleaning up vSphere VM: ${VM_NAME} ==="

# --------------------------------------------------------------------------
# Power off (ignore errors — VM may already be off or deleted)
# --------------------------------------------------------------------------
echo "Powering off VM..."
govc vm.power -off -force "${VM_NAME}" 2>/dev/null || true
sleep 5

# --------------------------------------------------------------------------
# Destroy VM
# --------------------------------------------------------------------------
echo "Destroying VM..."
if govc vm.destroy "${VM_NAME}" 2>/dev/null; then
    echo "VM ${VM_NAME} destroyed successfully"
else
    echo "WARNING: Could not destroy VM ${VM_NAME} (may already be deleted)"
fi

echo "=== vSphere cleanup complete ==="
