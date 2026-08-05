#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Source proxy config if present (SHARED_DIR is guaranteed in CI).
[[ -s "${SHARED_DIR}/proxy-conf.sh" ]] && source "${SHARED_DIR}/proxy-conf.sh"

# --------------------------------------------------------------------------
# Read vSphere credentials
# FIXME: Adjust key names to match the actual vsphere-elastic secret structure.
# --------------------------------------------------------------------------
typeset credsDir='/var/run/vsphere-credentials'

typeset _wasTracing=false
[[ $- == *x* ]] && _wasTracing=true
set +x

if [[ -f "${credsDir}/.vsphere_server" ]]; then
    GOVC_URL="$(< "${credsDir}/.vsphere_server")"
elif [[ -f "${credsDir}/server" ]]; then
    GOVC_URL="$(< "${credsDir}/server")"
else
    set -x
    echo "ERROR: Cannot find vSphere server in credentials mount" >&2
    ls -la "${credsDir}/" >&2 || true
    exit 1
fi

if [[ -f "${credsDir}/.vsphere_user" ]]; then
    GOVC_USERNAME="$(< "${credsDir}/.vsphere_user")"
elif [[ -f "${credsDir}/user" ]]; then
    GOVC_USERNAME="$(< "${credsDir}/user")"
else
    echo "ERROR: Cannot find vSphere user in credentials mount" >&2
    exit 1
fi

if [[ -f "${credsDir}/.vsphere_password" ]]; then
    GOVC_PASSWORD="$(< "${credsDir}/.vsphere_password")"
elif [[ -f "${credsDir}/password" ]]; then
    GOVC_PASSWORD="$(< "${credsDir}/.vsphere_password")"
else
    echo "ERROR: Cannot find vSphere password in credentials mount" >&2
    exit 1
fi

# Datacenter and datastore may come from the secret or fall back to env.
if [[ -f "${credsDir}/.vsphere_datacenter" ]]; then
    GOVC_DATACENTER="$(< "${credsDir}/.vsphere_datacenter")"
elif [[ -f "${credsDir}/datacenter" ]]; then
    GOVC_DATACENTER="$(< "${credsDir}/datacenter")"
else
    GOVC_DATACENTER="${GOVC_DATACENTER:-}"
fi

if [[ -f "${credsDir}/.vsphere_datastore" ]]; then
    GOVC_DATASTORE="$(< "${credsDir}/.vsphere_datastore")"
elif [[ -f "${credsDir}/datastore" ]]; then
    GOVC_DATASTORE="$(< "${credsDir}/datastore")"
else
    GOVC_DATASTORE="${GOVC_DATASTORE:-}"
fi

export GOVC_URL GOVC_USERNAME GOVC_PASSWORD
export GOVC_DATACENTER GOVC_DATASTORE
export GOVC_INSECURE="${GOVC_INSECURE:-true}"

[[ -f "${credsDir}/cacert" ]] && export GOVC_TLS_CA_CERTS="${credsDir}/cacert"

# Save non-sensitive govc context for downstream steps.
# Credentials (GOVC_USERNAME / GOVC_PASSWORD) are intentionally excluded —
# cleanup and cold-migration steps each have their own credential mount.
{
    printf 'export GOVC_URL=%q\n'        "${GOVC_URL}"
    printf 'export GOVC_DATACENTER=%q\n' "${GOVC_DATACENTER}"
    printf 'export GOVC_DATASTORE=%q\n'  "${GOVC_DATASTORE}"
    printf 'export GOVC_INSECURE=%q\n'   "${GOVC_INSECURE}"
    [[ -n "${GOVC_TLS_CA_CERTS:-}" ]] && printf 'export GOVC_TLS_CA_CERTS=%q\n' "${GOVC_TLS_CA_CERTS}"
} > "${SHARED_DIR}/govc-env.sh"

[[ "${_wasTracing}" == 'true' ]] && set -x

# --------------------------------------------------------------------------
# Verify connectivity
# --------------------------------------------------------------------------
govc about

# --------------------------------------------------------------------------
# Clone VM from template
# --------------------------------------------------------------------------
typeset vmName="${VM_NAME_PREFIX}-$(date +%s)"

typeset -a cloneArgs=(
    -vm  "${VSPHERE_TEMPLATE}"
    -m   "${VM_MEMORY_MB}"
    -c   "${VM_CPU_COUNT}"
    -on=false
    -annotation "MTV POC migration test VM — created by CI"
)

[[ -n "${VSPHERE_RESOURCE_POOL}" ]] && cloneArgs+=( -pool   "${VSPHERE_RESOURCE_POOL}" )
[[ -n "${VSPHERE_FOLDER}"        ]] && cloneArgs+=( -folder "${VSPHERE_FOLDER}"        )
[[ -n "${GOVC_DATASTORE}"        ]] && cloneArgs+=( -ds     "${GOVC_DATASTORE}"        )

cloneArgs+=( "${vmName}" )

govc vm.clone "${cloneArgs[@]}"

# Resize the first disk to the requested size — clone inherits the template default.
govc vm.disk.change -vm "${vmName}" -disk.label 'Hard disk 1' -size "${VM_DISK_GB}GB"

# --------------------------------------------------------------------------
# Power on and wait for IP
# --------------------------------------------------------------------------
govc vm.power -on "${vmName}"

typeset vmIp=''
typeset -i deadline=$(( SECONDS + 600 ))
while (( SECONDS < deadline )); do
    vmIp="$(govc vm.ip "${vmName}" 2>/dev/null || true)"
    [[ -n "${vmIp}" ]] && break
    : "Waiting for IP assignment (${SECONDS}s / 600s)"
    sleep 10
done

[[ -z "${vmIp}" ]] && vmIp='unknown'

# --------------------------------------------------------------------------
# Resolve VM inventory path
# --------------------------------------------------------------------------
typeset vmMoid=''
typeset vmFolderPath=''
vmMoid="$(govc vm.info -json "${vmName}" \
    | jq -r '.virtualMachines[0].self.value // empty' 2>/dev/null || true)"
vmFolderPath="$(govc vm.info "${vmName}" \
    | awk '/^\s*Path:/{print $2}' || true)"

# --------------------------------------------------------------------------
# Save VM metadata to SHARED_DIR using jq for correct JSON marshalling
# --------------------------------------------------------------------------
jq -n \
    --arg vmName       "${vmName}"       \
    --arg vmPath       "${vmFolderPath}" \
    --arg vmMoid       "${vmMoid}"       \
    --arg ipAddress    "${vmIp}"         \
    --arg datacenter   "${GOVC_DATACENTER}" \
    --arg datastore    "${GOVC_DATASTORE}"  \
    --arg network      "${VSPHERE_NETWORK}" \
    --arg vcenterHost  "${GOVC_URL}"        \
    --arg template     "${VSPHERE_TEMPLATE}" \
    '{
        vm_name:      $vmName,
        vm_path:      $vmPath,
        vm_moid:      $vmMoid,
        ip_address:   $ipAddress,
        datacenter:   $datacenter,
        datastore:    $datastore,
        network:      $network,
        vcenter_host: $vcenterHost,
        template:     $template
    }' > "${SHARED_DIR}/vsphere-source-vm.json"

# --------------------------------------------------------------------------
# Save VM info to artifacts
# --------------------------------------------------------------------------
mkdir -p "${ARTIFACT_DIR}"
govc vm.info "${vmName}" > "${ARTIFACT_DIR}/vsphere-source-vm-info.txt" 2>&1 || true

true
