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
require_commands yq-v4 mock-nss.sh virsh

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

# Host bridges and VXLAN lifecycle are managed by infra.
# Prefer lease vxlan.additional-bridge; fall back to VXLAN_ADDITIONAL_BRIDGE so
# rehearsals can proceed while the lease secret is still being updated.
ARM_BRIDGE_NAME="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".vxlan.\"additional-bridge\"" "${LEASE_CONF}" 2>/dev/null || true)"
if [[ -z "${ARM_BRIDGE_NAME}" || "${ARM_BRIDGE_NAME}" == "null" ]]; then
  if [[ -n "${VXLAN_ADDITIONAL_BRIDGE:-}" ]]; then
    echo "WARN: lease '${LEASED_RESOURCE}' missing vxlan.additional-bridge; using VXLAN_ADDITIONAL_BRIDGE=${VXLAN_ADDITIONAL_BRIDGE}"
    ARM_BRIDGE_NAME="${VXLAN_ADDITIONAL_BRIDGE}"
  else
    echo "ERROR: Couldn't find 'vxlan.additional-bridge' in lease config for '${LEASED_RESOURCE}'" >&2
    echo "ERROR: Set vxlan.additional-bridge in the cluster-profile lease secret, or set VXLAN_ADDITIONAL_BRIDGE on the job." >&2
    exit 1
  fi
fi
if [[ -z "${ARM_BRIDGE_NAME}" || "${ARM_BRIDGE_NAME}" =~ [^a-zA-Z0-9_-] ]]; then
  echo "ERROR: Invalid infrastructure additional bridge name '${ARM_BRIDGE_NAME}'" >&2
  exit 1
fi
printf '%s\n' "${ARM_BRIDGE_NAME}" > "${SHARED_DIR}/arm-bridge-name"

echo "Defining and starting primary libvirt network ${CLUSTER_NAME}..."
${VIRSH} net-define "${SHARED_DIR}/network.xml"
${VIRSH} net-autostart "${CLUSTER_NAME}"
${VIRSH} net-start "${CLUSTER_NAME}"

echo "Primary libvirt network started; VXLAN attachment is infra-managed."
