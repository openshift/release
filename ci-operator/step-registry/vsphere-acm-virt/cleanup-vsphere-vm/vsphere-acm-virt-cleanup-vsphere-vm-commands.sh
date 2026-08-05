#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Source proxy config if present (SHARED_DIR is guaranteed in CI).
[[ -s "${SHARED_DIR}/proxy-conf.sh" ]] && source "${SHARED_DIR}/proxy-conf.sh"

# --------------------------------------------------------------------------
# Load non-sensitive govc context from SHARED_DIR (no credentials inside).
# --------------------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/govc-env.sh" ]]; then
    : "No govc-env.sh found in SHARED_DIR — nothing to clean up"
    exit 0
fi

# shellcheck disable=SC1090
source "${SHARED_DIR}/govc-env.sh"

# --------------------------------------------------------------------------
# Read credentials from the mounted secret (never stored in SHARED_DIR).
# --------------------------------------------------------------------------
typeset credsDir='/var/run/vsphere-credentials'
typeset _wasTracing=false
[[ $- == *x* ]] && _wasTracing=true
set +x

[[ -f "${credsDir}/.vsphere_user"     ]] \
    && export GOVC_USERNAME="$(< "${credsDir}/.vsphere_user")"     \
    || { [[ -f "${credsDir}/user"     ]] && export GOVC_USERNAME="$(< "${credsDir}/user")"; } \
    || true
[[ -f "${credsDir}/.vsphere_password" ]] \
    && export GOVC_PASSWORD="$(< "${credsDir}/.vsphere_password")" \
    || { [[ -f "${credsDir}/password" ]] && export GOVC_PASSWORD="$(< "${credsDir}/password")"; } \
    || true

[[ "${_wasTracing}" == 'true' ]] && set -x

[[ -f "${credsDir}/cacert" ]] && export GOVC_TLS_CA_CERTS="${credsDir}/cacert"

# --------------------------------------------------------------------------
# Read VM name from metadata written by vsphere-acm-virt-create-source-vm.
# --------------------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/vsphere-source-vm.json" ]]; then
    : "No vsphere-source-vm.json found — nothing to clean up"
    exit 0
fi

typeset vmName=''
vmName="$(jq -r '.vm_name' "${SHARED_DIR}/vsphere-source-vm.json")"

if [[ -z "${vmName}" || "${vmName}" == 'null' ]]; then
    : "No VM name found in metadata — nothing to clean up"
    exit 0
fi

# --------------------------------------------------------------------------
# Power off (tolerate errors — VM may already be off or partially deleted).
# --------------------------------------------------------------------------
govc vm.power -off -force "${vmName}" 2>/dev/null || true

# Poll until the VM is powered off before issuing destroy.
(
    typeset -i wInt=5 wMax=60
    SECONDS=0
    while (( SECONDS < wMax )); do
        typeset powerState
        powerState="$(govc vm.info -json "${vmName}" \
            | jq -r '.virtualMachines[0].runtime.powerState // empty' 2>/dev/null || true)"
        [[ "${powerState}" == 'poweredOff' ]] && break
        : "Waiting for VM power-off (${SECONDS}/${wMax}s)"
        sleep "${wInt}"
    done
    true
)

# --------------------------------------------------------------------------
# Destroy VM (tolerate not-found — migration may have removed it already).
# --------------------------------------------------------------------------
govc vm.destroy "${vmName}" 2>/dev/null || true

true
