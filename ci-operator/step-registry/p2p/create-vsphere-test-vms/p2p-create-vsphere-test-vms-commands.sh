#!/bin/bash
#
# Create test VMware VMs in a leased vSphere environment (CI step).
#
# Reads the vSphere lease and vault credentials, creates one or more small
# VMs using govc, and writes the VM names and datastore/network IDs to
# SHARED_DIR for downstream MTV migration steps.
#
# Leasing:
#   VSPHERE_LEASED_RESOURCE: vsphere-connected-2 slice in format
#   "router.datacenter.vlanid"  (e.g. "bcr01a.dal10.1153")
#
# Vault credentials mounted at /var/run/vault/vsphere-ibmcloud-config/:
#   subnets.json               — VLAN topology: vCenter URL
#   load-vsphere-env-config.sh — sets vsphere_datacenter, vsphere_datastore,
#                                vsphere_cluster, VCENTER_AUTH_PATH
#
# Outputs to SHARED_DIR:
#   vsphere-vm-names           — newline-separated list of created VM names
#   vsphere-datastore-id       — vSphere datastore MoRef ID (for MTV StorageMap)
#   vsphere-portgroup-id       — vSphere portgroup MoRef ID (for MTV NetworkMap)
#   vsphere-vcenter-host       — vCenter hostname (for MTV Provider registration)
#   vsphere-datacenter         — vSphere datacenter name
#

set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq govc

typeset -r SUBNETS_CONFIG=/var/run/vault/vsphere-ibmcloud-config/subnets.json
typeset -r VSPHERE_ENV_SCRIPT=/var/run/vault/vsphere-ibmcloud-config/load-vsphere-env-config.sh

# =====================
# Input validation
# =====================
[[ -n "${VSPHERE_LEASED_RESOURCE}" ]]
[[ -f "${SUBNETS_CONFIG}" ]]
[[ -f "${VSPHERE_ENV_SCRIPT}" ]]

# =====================
# Parse vSphere lease: "router.datacenter.vlanid" (e.g. bcr01a.dal10.1153)
# =====================
typeset vlanRouter vlanPhydc vlanId vspherePortgroup primaryRouterHostname
vlanRouter="${VSPHERE_LEASED_RESOURCE%%.*}"
vlanPhydc="${VSPHERE_LEASED_RESOURCE#*.}"; vlanPhydc="${vlanPhydc%%.*}"
vlanId="${VSPHERE_LEASED_RESOURCE##*.}"
primaryRouterHostname="${vlanRouter}.${vlanPhydc}"
vspherePortgroup="ci-vlan-${vlanId}"

: "vSphere lease: router=${vlanRouter} dc=${vlanPhydc} vlan=${vlanId} portgroup=${vspherePortgroup}"

if ! jq -e --arg prh "${primaryRouterHostname}" --arg vid "${vlanId}" \
        '.[$prh] | has($vid)' "${SUBNETS_CONFIG}" 1>/dev/null; then
    : "ERROR: VLAN ${vlanId} not found in subnets.json for router ${primaryRouterHostname}"
    exit 1
fi

typeset vcenterHost
vcenterHost="$(jq -r --arg prh "${primaryRouterHostname}" --arg vid "${vlanId}" \
    '.[$prh][$vid].vcenter // empty' "${SUBNETS_CONFIG}")"
[[ -n "${vcenterHost}" ]]

# =====================
# Load vSphere environment config
# =====================
# shellcheck disable=SC1090
source "${VSPHERE_ENV_SCRIPT}"
[[ -n "${vsphere_datacenter:-}" ]]
[[ -n "${vsphere_datastore:-}" ]]
[[ -n "${vsphere_cluster:-}" ]]
[[ -n "${VCENTER_AUTH_PATH:-}" ]]
[[ -f "${VCENTER_AUTH_PATH}" ]]

# =====================
# Configure govc environment (credentials — disable xtrace)
# =====================
typeset vcenterUser vcenterPassword
( set +x
  vcenterUser="$(< "${VCENTER_AUTH_PATH}")"
  vcenterPassword="${vcenterUser#*:}"
  vcenterUser="${vcenterUser%%:*}"
  printf '%s' "${vcenterUser}" > "${SHARED_DIR}/vsphere-vcenter-user-tmp"
  printf '%s' "${vcenterPassword}" > "${SHARED_DIR}/vsphere-vcenter-password-tmp"
  true
)

# govc picks up credentials via environment — set without xtrace
set +x
export GOVC_URL="https://${vcenterHost}/sdk"
export GOVC_USERNAME="$(< "${SHARED_DIR}/vsphere-vcenter-user-tmp")"
export GOVC_PASSWORD="$(< "${SHARED_DIR}/vsphere-vcenter-password-tmp")"
export GOVC_INSECURE=1
export GOVC_DATACENTER="${vsphere_datacenter}"
export GOVC_DATASTORE="${vsphere_datastore}"
set -x

# Remove credential temp files now that govc env is set
rm -f "${SHARED_DIR}/vsphere-vcenter-user-tmp" "${SHARED_DIR}/vsphere-vcenter-password-tmp"

# =====================
# Verify govc connectivity
# =====================
govc about 1>/dev/null

# =====================
# Collect datastore MoRef ID for MTV StorageMap
# =====================
typeset datastoreId
datastoreId="$(
    govc datastore.info -json "${vsphere_datastore}" |
    jq -r '.[0].Self.Value // empty'
)"
[[ -n "${datastoreId}" ]]
: "Datastore MoRef: ${datastoreId}"

# =====================
# Collect portgroup MoRef ID for MTV NetworkMap
# =====================
typeset portgroupId
portgroupId="$(
    govc network.info -json "${vspherePortgroup}" 2>/dev/null |
    jq -r '.[0].Self.Value // empty'
)"
if [[ -z "${portgroupId}" ]]; then
    : "WARNING: portgroup ${vspherePortgroup} not found via network.info — using name as fallback"
    portgroupId="${vspherePortgroup}"
fi
: "Portgroup ID: ${portgroupId}"

# =====================
# Create test VMs
# =====================
typeset -i vmCount="${P2P_MTV_VSPHERE_VM_COUNT}"
typeset -a createdVMs=()
typeset vmName i

for ((i = 1; i <= vmCount; i++)); do
    vmName="${P2P_MTV_VSPHERE_VM_NAME_PREFIX}-${i}"
    : "Creating VM: ${vmName}"

    if govc vm.info "${vmName}" 1>/dev/null 2>&1; then
        : "VM ${vmName} already exists — skipping create"
    else
        govc vm.create \
            -m "${P2P_MTV_VSPHERE_VM_MEMORY_MB}" \
            -c "${P2P_MTV_VSPHERE_VM_CPUS}" \
            -disk "${P2P_MTV_VSPHERE_VM_DISK_SIZE}" \
            -disk.controller scsi \
            -net "${vspherePortgroup}" \
            -ds "${vsphere_datastore}" \
            -folder "/${vsphere_datacenter}/vm" \
            -on=false \
            "${vmName}"
    fi

    createdVMs+=("${vmName}")
done

# Optionally power on VMs (required for warm migration)
if [[ "${P2P_MTV_VSPHERE_VM_POWER_ON}" == "true" ]]; then
    for vmName in "${createdVMs[@]}"; do
        govc vm.power -on "${vmName}"
    done
fi

# =====================
# Write outputs to SHARED_DIR
# =====================
printf '%s\n' "${createdVMs[@]}" > "${SHARED_DIR}/vsphere-vm-names"
printf '%s' "${datastoreId}"     > "${SHARED_DIR}/vsphere-datastore-id"
printf '%s' "${portgroupId}"     > "${SHARED_DIR}/vsphere-portgroup-id"
printf '%s' "${vcenterHost}"     > "${SHARED_DIR}/vsphere-vcenter-host"
printf '%s' "${vsphere_datacenter}" > "${SHARED_DIR}/vsphere-datacenter"

# =====================
# Artifacts
# =====================
{
    govc vm.info "${createdVMs[@]}" 2>/dev/null || true
} > "${ARTIFACT_DIR}/vsphere-test-vms-info.txt"

: "Created ${#createdVMs[@]} test VM(s): ${createdVMs[*]}"
: "Datastore MoRef: ${datastoreId}"
: "Portgroup ID: ${portgroupId}"
true
