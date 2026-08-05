#!/bin/bash
#
# Create a RHEL9 source VM on vSphere using govc for MTV cold migration testing.
#
# The VM is cloned from a template, configured, and powered on.
# VM metadata is written to SHARED_DIR for consumption by the cold-migration
# and cleanup-vsphere-vm steps.
#
set -euxo pipefail

if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# --------------------------------------------------------------------------
# Read vSphere credentials
# --------------------------------------------------------------------------
# FIXME: The exact key names in the vsphere-elastic secret may differ.
# Adjust the filenames below to match the actual secret structure.
# Common patterns: .vsphere_server / .vcenter_host, .vsphere_user, etc.
CREDS_DIR="/var/run/vsphere-credentials"

# Disable tracing while reading credentials
_was_tracing=false
[[ $- == *x* ]] && _was_tracing=true
set +x

if [[ -f "${CREDS_DIR}/.vsphere_server" ]]; then
    GOVC_URL="$(< "${CREDS_DIR}/.vsphere_server")"
elif [[ -f "${CREDS_DIR}/server" ]]; then
    GOVC_URL="$(< "${CREDS_DIR}/server")"
else
    echo "ERROR: Cannot find vSphere server in credentials mount" >&2
    ls -la "${CREDS_DIR}/" >&2 || true
    exit 1
fi

if [[ -f "${CREDS_DIR}/.vsphere_user" ]]; then
    GOVC_USERNAME="$(< "${CREDS_DIR}/.vsphere_user")"
elif [[ -f "${CREDS_DIR}/user" ]]; then
    GOVC_USERNAME="$(< "${CREDS_DIR}/user")"
else
    echo "ERROR: Cannot find vSphere user in credentials mount" >&2
    exit 1
fi

if [[ -f "${CREDS_DIR}/.vsphere_password" ]]; then
    GOVC_PASSWORD="$(< "${CREDS_DIR}/.vsphere_password")"
elif [[ -f "${CREDS_DIR}/password" ]]; then
    GOVC_PASSWORD="$(< "${CREDS_DIR}/password")"
else
    echo "ERROR: Cannot find vSphere password in credentials mount" >&2
    exit 1
fi

# Datacenter and datastore — may come from secret or env
if [[ -f "${CREDS_DIR}/.vsphere_datacenter" ]]; then
    GOVC_DATACENTER="$(< "${CREDS_DIR}/.vsphere_datacenter")"
elif [[ -f "${CREDS_DIR}/datacenter" ]]; then
    GOVC_DATACENTER="$(< "${CREDS_DIR}/datacenter")"
else
    GOVC_DATACENTER="${GOVC_DATACENTER:-}"
fi

if [[ -f "${CREDS_DIR}/.vsphere_datastore" ]]; then
    GOVC_DATASTORE="$(< "${CREDS_DIR}/.vsphere_datastore")"
elif [[ -f "${CREDS_DIR}/datastore" ]]; then
    GOVC_DATASTORE="$(< "${CREDS_DIR}/datastore")"
else
    GOVC_DATASTORE="${GOVC_DATASTORE:-}"
fi

export GOVC_URL GOVC_USERNAME GOVC_PASSWORD
export GOVC_DATACENTER GOVC_DATASTORE
export GOVC_INSECURE="${GOVC_INSECURE:-true}"

# TLS CA certs (optional)
if [[ -f "${CREDS_DIR}/cacert" ]]; then
    export GOVC_TLS_CA_CERTS="${CREDS_DIR}/cacert"
fi

# Save govc env for the cleanup step (no passwords logged)
{
    echo "export GOVC_URL='${GOVC_URL}'"
    echo "export GOVC_USERNAME='${GOVC_USERNAME}'"
    echo "export GOVC_PASSWORD='${GOVC_PASSWORD}'"
    echo "export GOVC_DATACENTER='${GOVC_DATACENTER}'"
    echo "export GOVC_DATASTORE='${GOVC_DATASTORE}'"
    echo "export GOVC_INSECURE='${GOVC_INSECURE}'"
    [[ -n "${GOVC_TLS_CA_CERTS:-}" ]] && echo "export GOVC_TLS_CA_CERTS='${GOVC_TLS_CA_CERTS}'"
} > "${SHARED_DIR}/govc-env.sh"
chmod 0600 "${SHARED_DIR}/govc-env.sh"

$_was_tracing && set -x

# --------------------------------------------------------------------------
# Verify govc connectivity
# --------------------------------------------------------------------------
echo "=== Verifying vSphere connectivity ==="
govc about

# --------------------------------------------------------------------------
# Create VM
# --------------------------------------------------------------------------
VM_NAME="${VM_NAME_PREFIX}-$(date +%s)"
echo "=== Creating VM: ${VM_NAME} ==="

# Build govc vm.clone command
clone_args=(
    -vm "${VSPHERE_TEMPLATE}"
    -m "${VM_MEMORY_MB}"
    -c "${VM_CPU_COUNT}"
    -on=false
    -annotation "MTV POC migration test VM — created by CI"
)

if [[ -n "${VSPHERE_RESOURCE_POOL}" ]]; then
    clone_args+=( -pool "${VSPHERE_RESOURCE_POOL}" )
fi

if [[ -n "${VSPHERE_FOLDER}" ]]; then
    clone_args+=( -folder "${VSPHERE_FOLDER}" )
fi

if [[ -n "${GOVC_DATASTORE}" ]]; then
    clone_args+=( -ds "${GOVC_DATASTORE}" )
fi

clone_args+=( "${VM_NAME}" )

govc vm.clone "${clone_args[@]}"

echo "VM cloned successfully: ${VM_NAME}"

# --------------------------------------------------------------------------
# Power on and wait for IP
# --------------------------------------------------------------------------
echo "=== Powering on VM ==="
govc vm.power -on "${VM_NAME}"

echo "=== Waiting for VM to acquire an IP address ==="
VM_IP=""
deadline=$(( SECONDS + 600 ))  # 10 min
while (( SECONDS < deadline )); do
    VM_IP="$(govc vm.ip "${VM_NAME}" 2>/dev/null || true)"
    if [[ -n "${VM_IP}" ]]; then
        echo "VM IP: ${VM_IP}"
        break
    fi
    echo "Waiting for IP assignment... (${SECONDS}s elapsed)"
    sleep 10
done

if [[ -z "${VM_IP}" ]]; then
    echo "WARNING: VM did not acquire an IP within timeout; proceeding without IP"
    VM_IP="unknown"
fi

# --------------------------------------------------------------------------
# Resolve VM inventory path
# --------------------------------------------------------------------------
VM_PATH="$(govc vm.info -json "${VM_NAME}" | jq -r '.virtualMachines[0].self.value // empty' || true)"
VM_FOLDER_PATH="$(govc vm.info "${VM_NAME}" | grep 'Path:' | awk '{print $2}' || true)"

# --------------------------------------------------------------------------
# Save VM metadata to SHARED_DIR
# --------------------------------------------------------------------------
cat > "${SHARED_DIR}/vsphere-source-vm.json" <<VMJSON
{
    "vm_name": "${VM_NAME}",
    "vm_path": "${VM_FOLDER_PATH}",
    "vm_moid": "${VM_PATH}",
    "ip_address": "${VM_IP}",
    "datacenter": "${GOVC_DATACENTER}",
    "datastore": "${GOVC_DATASTORE}",
    "network": "${VSPHERE_NETWORK}",
    "vcenter_host": "${GOVC_URL}",
    "template": "${VSPHERE_TEMPLATE}"
}
VMJSON

echo "VM metadata saved to ${SHARED_DIR}/vsphere-source-vm.json"
cat "${SHARED_DIR}/vsphere-source-vm.json"

# --------------------------------------------------------------------------
# Save summary to artifacts
# --------------------------------------------------------------------------
if [[ -n "${ARTIFACT_DIR:-}" ]]; then
    mkdir -p "${ARTIFACT_DIR}"
    govc vm.info "${VM_NAME}" > "${ARTIFACT_DIR}/vsphere-source-vm-info.txt" 2>&1 || true
fi

echo "=== Source VM creation complete ==="
