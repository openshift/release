#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

require_commands() {
  local cmd
  local -a missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    printf 'ERROR: missing dependencies: %s\n' "${missing[*]}" >&2
    printf 'Fix the step image before retrying.\n' >&2
    exit 1
  fi
}

# Local (CI-container) commands required for this step
require_commands yq-v4 mock-nss.sh virsh ssh

# Ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE:-}" ]]; then
  echo "ERROR: Failed to acquire lease"
  exit 1
fi

# Ensure leases file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "ERROR: Couldn't find lease config file"
  exit 1
fi

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"

# Verify the lease record exists
if [[ "$(yq-v4 -oy "has(\"${LEASED_RESOURCE}\")" "${LEASE_CONF}")" != "true" ]]; then
  echo "ERROR: Leased resource '${LEASED_RESOURCE}' not found in ${LEASE_CONF}"
  exit 1
fi

function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${LEASE_CONF}")
  if [[ -z "${lookup}" || "${lookup}" == "null" ]]; then
    echo "ERROR: Couldn't find '${1}' in lease config for '${LEASED_RESOURCE}'" >&2
    exit 1
  fi
  echo "$lookup"
}

# Ensure hostname can be found
HOSTNAME="$(leaseLookup 'hostname')"

REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME}/system"
VIRSH="mock-nss.sh virsh --connect ${REMOTE_LIBVIRT_URI}"

if [ "${USE_EXTERNAL_DNS:-false}" == "true" ]; then
  CLUSTER_NAME="${LEASED_RESOURCE}"
else
  CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
fi

if [[ ! -f "${SHARED_DIR}/network.xml" ]]; then
  echo "ERROR: Missing ${SHARED_DIR}/network.xml"
  exit 1
fi

# ---------------------------------------------------------------------------
# Read and validate VXLAN configuration from the lease's private profile.
# These fields are expected under .${LEASED_RESOURCE}.vxlan in the profile.
# ---------------------------------------------------------------------------
VXLAN_LOCAL_IP="$(leaseLookup 'vxlan.local-ip')"
VXLAN_REMOTE_IP="$(leaseLookup 'vxlan.remote-ip')"
VXLAN_ID="$(leaseLookup 'vxlan.id')"
VXLAN_PORT="$(leaseLookup 'vxlan.dstport')"
VXLAN_INTERFACE="$(leaseLookup 'vxlan.interface')"
ARM_BRIDGE_NAME="$(leaseLookup 'vxlan.additional-bridge')"

# Validate VXLAN field formats
if [[ ! "${VXLAN_LOCAL_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "ERROR: vxlan.local-ip '${VXLAN_LOCAL_IP}' is not a valid IPv4 address"
  exit 1
fi
if [[ ! "${VXLAN_REMOTE_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "ERROR: vxlan.remote-ip '${VXLAN_REMOTE_IP}' is not a valid IPv4 address"
  exit 1
fi
if [[ ! "${VXLAN_ID}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: vxlan.id '${VXLAN_ID}' is not a positive integer"
  exit 1
fi
if [[ ! "${VXLAN_PORT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: vxlan.dstport '${VXLAN_PORT}' is not a positive integer"
  exit 1
fi
if [[ -z "${VXLAN_INTERFACE}" || "${VXLAN_INTERFACE}" =~ [^a-zA-Z0-9_-] ]]; then
  echo "ERROR: vxlan.interface '${VXLAN_INTERFACE}' is empty or contains unexpected characters"
  exit 1
fi
if [[ -z "${ARM_BRIDGE_NAME}" || "${ARM_BRIDGE_NAME}" =~ [^a-zA-Z0-9_-] ]]; then
  echo "ERROR: vxlan.additional-bridge '${ARM_BRIDGE_NAME}' is empty or contains unexpected characters"
  exit 1
fi

# Export for use by downstream steps
export ARM_BRIDGE_NAME
echo "${ARM_BRIDGE_NAME}" > "${SHARED_DIR}/arm-bridge-name"

# ---------------------------------------------------------------------------
# SSH helper: run_primary <cmd...>
# Executes commands on the primary hypervisor over authenticated SSH.
# Identity file and known_hosts are provisioned by infra through the profile;
# they must exist at the expected paths before this step runs.
# ---------------------------------------------------------------------------
SSH_KEY="${CLUSTER_PROFILE_DIR}/ssh-hypervisor-key"
SSH_KNOWN_HOSTS="${CLUSTER_PROFILE_DIR}/ssh-hypervisor-known-hosts"

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "ERROR: Hypervisor SSH key not found at ${SSH_KEY}; infra must provision this in the cluster profile"
  exit 1
fi
if [[ ! -f "${SSH_KNOWN_HOSTS}" ]]; then
  echo "ERROR: Hypervisor known_hosts not found at ${SSH_KNOWN_HOSTS}; infra must provision this in the cluster profile"
  exit 1
fi

run_primary() {
  ssh \
    -i "${SSH_KEY}" \
    -o BatchMode=yes \
    -o ConnectTimeout=30 \
    -o UserKnownHostsFile="${SSH_KNOWN_HOSTS}" \
    -o StrictHostKeyChecking=yes \
    "root@${HOSTNAME}" \
    "$@"
}

echo "Defining and starting libvirt network ${CLUSTER_NAME} on primary hypervisor..."
${VIRSH} net-define "${SHARED_DIR}/network.xml"
${VIRSH} net-autostart "${CLUSTER_NAME}"
${VIRSH} net-start "${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# Discover the bridge name libvirt assigned to this network.
# ---------------------------------------------------------------------------
BRIDGE_NAME=$(${VIRSH} net-dumpxml "${CLUSTER_NAME}" |
  yq-v4 -p=xml --xml-attribute-prefix='@' -oy \
    '.network.bridge."@name"')
if [[ -z "${BRIDGE_NAME}" || "${BRIDGE_NAME}" == "null" ]]; then
  echo "ERROR: Could not determine bridge name for libvirt network '${CLUSTER_NAME}'"
  exit 1
fi

# ---------------------------------------------------------------------------
# Verify that local-ip is actually assigned on the primary hypervisor and
# that its route to remote-ip uses the intended underlay path.
# ---------------------------------------------------------------------------
echo "Verifying VXLAN underlay addresses on primary hypervisor..."
run_primary bash -s -- "${VXLAN_LOCAL_IP}" "${VXLAN_REMOTE_IP}" <<'PREFLIGHT'
set -euo pipefail
local_ip=$1; remote_ip=$2
if ! ip addr show | grep -qF "${local_ip}"; then
  echo "ERROR: vxlan.local-ip ${local_ip} is not assigned on primary hypervisor" >&2
  exit 1
fi
route_dev=$(ip route get "${remote_ip}" | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
echo "INFO: Route to ${remote_ip} uses device: ${route_dev}"
PREFLIGHT

# ---------------------------------------------------------------------------
# Create the job-owned VXLAN endpoint on the primary hypervisor.
# Refuse to proceed if an endpoint with the same name already exists.
# ---------------------------------------------------------------------------
VXLAN_OWNER="ci:${LEASED_RESOURCE}"
echo "Creating VXLAN endpoint ${VXLAN_INTERFACE} on primary hypervisor (bridge=${BRIDGE_NAME}, VNI=${VXLAN_ID}, port=${VXLAN_PORT})..."
run_primary bash -s -- \
  "${BRIDGE_NAME}" "${VXLAN_LOCAL_IP}" "${VXLAN_REMOTE_IP}" \
  "${VXLAN_ID}" "${VXLAN_PORT}" "${VXLAN_INTERFACE}" \
  "${VXLAN_OWNER}" <<'REMOTE'
set -euo pipefail
bridge=$1; local_ip=$2; remote_ip=$3
vni=$4; port=$5; iface=$6; owner=$7

# Verify the bridge exists
if ! test -d "/sys/class/net/${bridge}/bridge"; then
  echo "ERROR: Bridge ${bridge} does not exist or is not a bridge on primary hypervisor" >&2
  exit 1
fi

# Refuse to overwrite an existing endpoint — stale endpoint requires manual inspection
if test -e "/sys/class/net/${iface}"; then
  echo "ERROR: VXLAN endpoint ${iface} already exists on primary hypervisor;" \
       " inspect ownership/pre-cleanup before retrying" >&2
  exit 1
fi

ip link add "${iface}" type vxlan id "${vni}" \
  local "${local_ip}" remote "${remote_ip}" dstport "${port}"
ip link set dev "${iface}" alias "${owner}"
ip link set dev "${iface}" master "${bridge}"
ip link set dev "${iface}" up
REMOTE

# ---------------------------------------------------------------------------
# Verify VXLAN endpoint state after creation: read back all attributes.
# ---------------------------------------------------------------------------
echo "Verifying VXLAN endpoint ${VXLAN_INTERFACE} state on primary hypervisor..."
run_primary bash -s -- \
  "${VXLAN_INTERFACE}" "${VXLAN_ID}" "${VXLAN_LOCAL_IP}" "${VXLAN_REMOTE_IP}" \
  "${VXLAN_PORT}" "${BRIDGE_NAME}" "${VXLAN_OWNER}" <<'VERIFY'
set -euo pipefail
iface=$1; vni=$2; local_ip=$3; remote_ip=$4; port=$5; bridge=$6; owner=$7

fail() { echo "ERROR: VXLAN verify: $*" >&2; exit 1; }

actual_type=$(ip -d link show "${iface}" 2>/dev/null | awk '/vxlan/{print "vxlan"; exit}')
[[ "${actual_type}" == "vxlan" ]] || fail "interface type is not vxlan"

actual_id=$(ip -d link show "${iface}" | grep -oP 'id \K[0-9]+' | head -1)
[[ "${actual_id}" == "${vni}" ]] || fail "VNI mismatch: expected ${vni}, got ${actual_id}"

actual_local=$(ip -d link show "${iface}" | grep -oP 'local \K[0-9.]+' | head -1)
[[ "${actual_local}" == "${local_ip}" ]] || fail "local address mismatch: expected ${local_ip}, got ${actual_local}"

actual_remote=$(ip -d link show "${iface}" | grep -oP 'remote \K[0-9.]+' | head -1)
[[ "${actual_remote}" == "${remote_ip}" ]] || fail "remote address mismatch: expected ${remote_ip}, got ${actual_remote}"

actual_port=$(ip -d link show "${iface}" | grep -oP 'dstport \K[0-9]+' | head -1)
[[ "${actual_port}" == "${port}" ]] || fail "dstport mismatch: expected ${port}, got ${actual_port}"

actual_master=$(cat "/sys/class/net/${iface}/master/dup_addr_detect_transmits" 2>/dev/null \
  && basename "$(readlink -f "/sys/class/net/${iface}/master")" 2>/dev/null || true)
actual_master=$(basename "$(readlink -f "/sys/class/net/${iface}/master")" 2>/dev/null || true)
[[ "${actual_master}" == "${bridge}" ]] || fail "bridge membership mismatch: expected ${bridge}, got ${actual_master}"

actual_state=$(ip link show "${iface}" | grep -oP '(?<=state )\S+' | head -1)
[[ "${actual_state}" == "UP" || "${actual_state}" == "UNKNOWN" ]] \
  || fail "interface is not UP (state=${actual_state})"

actual_alias=$(ip link show "${iface}" | grep -oP '(?<=alias )\S+' | head -1)
[[ "${actual_alias}" == "${owner}" ]] || fail "owner alias mismatch: expected ${owner}, got ${actual_alias}"

echo "INFO: VXLAN endpoint ${iface} verified: type=vxlan id=${vni} local=${local_ip}" \
     " remote=${remote_ip} dstport=${port} bridge=${bridge} state=${actual_state}"
VERIFY

echo "Libvirt network ${CLUSTER_NAME} successfully started and VXLAN endpoint ${VXLAN_INTERFACE} verified."
