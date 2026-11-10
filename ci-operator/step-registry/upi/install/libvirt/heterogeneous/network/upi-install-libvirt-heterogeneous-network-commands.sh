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

# Resolve the infra-owned VXLAN bridge on the additional hypervisor.
# Prefer lease 'vxlan.additional-bridge'; then VXLAN_ADDITIONAL_BRIDGE; then
# known lease→bridge mappings for VPN hetero slots.
resolve_additional_bridge() {
  local bridge
  bridge="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".vxlan.\"additional-bridge\"" "${LEASE_CONF}" 2>/dev/null || true)"
  if [[ -n "${bridge}" && "${bridge}" != "null" ]]; then
    printf '%s\n' "${bridge}"
    return 0
  fi

  if [[ -n "${VXLAN_ADDITIONAL_BRIDGE:-}" ]]; then
    echo "WARN: lease '${LEASED_RESOURCE}' missing 'vxlan.additional-bridge'; using environment variable VXLAN_ADDITIONAL_BRIDGE=${VXLAN_ADDITIONAL_BRIDGE}" >&2
    printf '%s\n' "${VXLAN_ADDITIONAL_BRIDGE}"
    return 0
  fi

  # Last-resort infra VXLAN bridges when leases.yaml omits 'vxlan.additional-bridge'.
  # Observed VPN wiring: amd64 ...-0-0 → ocp1-amd, ...-0-1 → ocp3-amd;
  # arm64 (profile libvirt-s390x-vpn-arm64 leases as libvirt-s390x-arm64-0-0) → ocp2-arm.
  case "${LEASED_RESOURCE}" in
    libvirt-s390x-vpn-amd64-0-0)
      bridge="ocp1-amd"
      ;;
    libvirt-s390x-vpn-amd64-0-1)
      bridge="ocp3-amd"
      ;;
    libvirt-s390x-arm64-0-0|libvirt-s390x-vpn-arm64-0-0|*-arm64-0-0)
      bridge="ocp2-arm"
      ;;
    *)
      bridge=""
      ;;
  esac

  if [[ -n "${bridge}" ]]; then
    echo "WARN: lease '${LEASED_RESOURCE}' missing 'vxlan.additional-bridge'; using known mapping → ${bridge}" >&2
    printf '%s\n' "${bridge}"
    return 0
  fi

  echo "ERROR: Couldn't resolve additional-host VXLAN bridge for '${LEASED_RESOURCE}'" >&2
  echo "ERROR: Set 'vxlan.additional-bridge' in the cluster-profile lease secret, or set the environment variable VXLAN_ADDITIONAL_BRIDGE in the job definition." >&2
  return 1
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

ADDITIONAL_BRIDGE_NAME="$(resolve_additional_bridge)"
if [[ -z "${ADDITIONAL_BRIDGE_NAME}" || "${ADDITIONAL_BRIDGE_NAME}" =~ [^a-zA-Z0-9_-] ]]; then
  echo "ERROR: Invalid infrastructure additional bridge name '${ADDITIONAL_BRIDGE_NAME}'" >&2
  exit 1
fi

# Publish for the heterogeneous installer / cleanup steps.
printf '%s\n' "${ADDITIONAL_BRIDGE_NAME}" > "${SHARED_DIR}/additional-bridge-name"
echo "Additional-host VXLAN bridge: ${ADDITIONAL_BRIDGE_NAME}"

echo "Using libvirt connection ${REMOTE_LIBVIRT_URI}"
echo "Defining and starting primary libvirt network ${CLUSTER_NAME}..."

# Both lease slots on this host can share the same subnet/bridge (e.g. ocp1).
# A stale network from a prior run on a *different* slot leaves the bridge occupied
# under a different network name, so checking by CLUSTER_NAME alone is not enough.
BRIDGE_NAME=$(grep -oP "(?<=<bridge name=')[^']+" "${SHARED_DIR}/network.xml" || true)

if [[ -n "${BRIDGE_NAME}" ]]; then
  echo "Target primary bridge: ${BRIDGE_NAME} — scanning for any network already holding it..."
  for NET in $(${VIRSH} net-list --all --name 2>/dev/null); do
    [[ -z "${NET}" ]] && continue
    NET_BRIDGE=$(${VIRSH} net-info "${NET}" 2>/dev/null | awk '/^Bridge:/{print $2}' || true)
    if [[ "${NET_BRIDGE}" == "${BRIDGE_NAME}" ]]; then
      # Only reclaim networks owned by this lease; never destroy a concurrent job's network.
      if [[ "${NET}" == "${LEASED_RESOURCE}" || "${NET}" == "${LEASED_RESOURCE}-"* || "${NET}" == "${LEASED_RESOURCE}."* ]]; then
        echo "Removing stale lease network '${NET}' (bridge ${BRIDGE_NAME})..."
        ${VIRSH} net-destroy "${NET}" 2>/dev/null || true
        ${VIRSH} net-undefine "${NET}" 2>/dev/null || true
      else
        echo "ERROR: bridge ${BRIDGE_NAME} is held by foreign network '${NET}'; refusing to reclaim" >&2
        exit 1
      fi
    fi
  done
fi

if ${VIRSH} net-info "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "Removing stale network '${CLUSTER_NAME}' by name..."
  ${VIRSH} net-destroy "${CLUSTER_NAME}" 2>/dev/null || true
  ${VIRSH} net-undefine "${CLUSTER_NAME}" 2>/dev/null || true
fi

${VIRSH} net-define "${SHARED_DIR}/network.xml"
${VIRSH} net-autostart "${CLUSTER_NAME}"
${VIRSH} net-start "${CLUSTER_NAME}"

# net-start can return before net-info reports Active=yes (seen in VPN rehearse).
# Retry briefly; the working non-hetero network step does not hard-fail immediately.
network_active=false
for (( i=1; i<=15; i++ )); do
  active="$(${VIRSH} net-info "${CLUSTER_NAME}" 2>/dev/null | awk '/^Active:/{print $2; exit}' || true)"
  if [[ "${active}" == "yes" ]]; then
    network_active=true
    break
  fi
  # Fallback: net-list State column (same truth as Active in practice).
  if ${VIRSH} net-list --all 2>/dev/null | awk -v n="${CLUSTER_NAME}" '$1==n && $2=="active" {found=1} END{exit !found}'; then
    network_active=true
    break
  fi
  sleep 1
done

if [[ "${network_active}" != "true" ]]; then
  echo "ERROR: Libvirt network ${CLUSTER_NAME} defined but not active after wait"
  ${VIRSH} net-list --all || true
  ${VIRSH} net-info "${CLUSTER_NAME}" || true
  exit 1
fi

echo "Active networks post creation:"
${VIRSH} net-list --all
printf '%s\n' "${CLUSTER_NAME}" > "${SHARED_DIR}/libvirt-network-name"
echo "Primary libvirt network started; VXLAN attachment is infra-managed."
