#!/bin/bash

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

require_commands yq-v4 mock-nss.sh virsh grep awk sleep

# Ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE:-}" ]]; then
  echo "ERROR: Failed to acquire lease (LEASED_RESOURCE is unset)"
  exit 1
fi

# Ensure leases file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "ERROR: Couldn't find lease config file"
  exit 1
fi

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"

HOSTNAME_PRIMARY="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".hostname" "${LEASE_CONF}")"
HOSTNAME_ADDITIONAL="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"hostname-additional\"" "${LEASE_CONF}")"

# Expected infra VXLAN bridge for the lease-owned additional libvirt network.
resolve_expected_additional_bridge() {
  local bridge
  bridge="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".vxlan.\"additional-bridge\"" "${LEASE_CONF}" 2>/dev/null || true)"
  if [[ -n "${bridge}" && "${bridge}" != "null" ]]; then
    printf '%s\n' "${bridge}"
    return 0
  fi
  if [[ -f "${SHARED_DIR}/additional-bridge-name" ]]; then
    printf '%s\n' "$(< "${SHARED_DIR}/additional-bridge-name")"
    return 0
  fi
  if [[ -f "${SHARED_DIR}/arm-bridge-name" ]]; then
    printf '%s\n' "$(< "${SHARED_DIR}/arm-bridge-name")"
    return 0
  fi
  if [[ -n "${VXLAN_ADDITIONAL_BRIDGE:-}" ]]; then
    printf '%s\n' "${VXLAN_ADDITIONAL_BRIDGE}"
    return 0
  fi
  case "${LEASED_RESOURCE}" in
    libvirt-s390x-vpn-amd64-0-0) printf '%s\n' "ocp3-amd" ;;
    libvirt-s390x-vpn-amd64-0-1) printf '%s\n' "ocp1-amd" ;;
    libvirt-s390x-arm64-0-0|*-arm64-0-0) printf '%s\n' "ocp2-arm" ;;
    *) printf '%s\n' "" ;;
  esac
}

if [[ -z "${HOSTNAME_PRIMARY}" || "${HOSTNAME_PRIMARY}" == "null" ]]; then
  echo "ERROR: Couldn't retrieve primary hostname from lease config"
  exit 1
fi

if [[ -z "${HOSTNAME_ADDITIONAL}" || "${HOSTNAME_ADDITIONAL}" == "null" ]]; then
  echo "ERROR: Couldn't retrieve additional hostname from lease config"
  exit 1
fi

ADDITIONAL_PORT="${ADDITIONAL_LIBVIRT_PORT:-16509}"
if [[ ! "${ADDITIONAL_PORT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Invalid ADDITIONAL_LIBVIRT_PORT '${ADDITIONAL_PORT}'"
  exit 1
fi

PRIMARY_LIBVIRT_URI="qemu+tcp://${HOSTNAME_PRIMARY}/system"
ADDITIONAL_LIBVIRT_URI="qemu+tcp://${HOSTNAME_ADDITIONAL}:${ADDITIONAL_PORT}/system"

VIRSH_PRIMARY="mock-nss.sh virsh --connect ${PRIMARY_LIBVIRT_URI}"
VIRSH_ADDITIONAL="mock-nss.sh virsh --connect ${ADDITIONAL_LIBVIRT_URI}"

echo "Verifying libvirt connectivity to primary and additional hypervisors..."
if ! ${VIRSH_PRIMARY} list >/dev/null; then
  echo "ERROR: Failed to connect or list domains on primary hypervisor"
  exit 1
fi

if ! ${VIRSH_ADDITIONAL} list >/dev/null; then
  echo "ERROR: Failed to connect or list domains on additional hypervisor"
  exit 1
fi

set +e

# --- Clean Primary Host ---
PRIMARY_INIT_DOMAINS=$(${VIRSH_PRIMARY} list --all --name 2>&1) || {
  echo "ERROR: Failed to list initial domains on primary hypervisor: ${PRIMARY_INIT_DOMAINS}"
  exit 1
}

echo "Removing stale domains on primary host matching lease '${LEASED_RESOURCE}'..."
for DOMAIN in $(echo "${PRIMARY_INIT_DOMAINS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)"); do
  ${VIRSH_PRIMARY} destroy "${DOMAIN}" >/dev/null 2>&1 || true
  sleep 1s
  ${VIRSH_PRIMARY} undefine "${DOMAIN}" >/dev/null 2>&1 || true
done

echo "Removing stale CI pool volumes on primary host..."
if ${VIRSH_PRIMARY} pool-list 2>/dev/null | grep -qw "${POOL_NAME}"; then
  PRIMARY_INIT_VOLS=$(${VIRSH_PRIMARY} vol-list --pool "${POOL_NAME}" 2>&1) || {
    echo "ERROR: Failed to list initial volumes on primary pool ${POOL_NAME}: ${PRIMARY_INIT_VOLS}"
    exit 1
  }
  for VOLUME in $(echo "${PRIMARY_INIT_VOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" | awk '{ print $1 }'); do
    ${VIRSH_PRIMARY} vol-delete --pool "${POOL_NAME}" "${VOLUME}" >/dev/null 2>&1 || true
  done
fi

echo "Removing stale httpd volumes on primary host..."
PRIMARY_INIT_ALL_POOLS=$(${VIRSH_PRIMARY} pool-list --all --name 2>&1) || {
  echo "ERROR: Failed to list pools on primary hypervisor during initial httpd pool check: ${PRIMARY_INIT_ALL_POOLS}"
  exit 1
}
if echo "${PRIMARY_INIT_ALL_POOLS}" | grep -Fxq "${HTTPD_POOL_NAME}"; then
  PRIMARY_INIT_HTTPD_VOLS=$(${VIRSH_PRIMARY} vol-list --pool "${HTTPD_POOL_NAME}" 2>&1) || {
    echo "ERROR: Failed to list initial volumes on primary httpd pool ${HTTPD_POOL_NAME}: ${PRIMARY_INIT_HTTPD_VOLS}"
    exit 1
  }
  for VOLUME in $(echo "${PRIMARY_INIT_HTTPD_VOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" | awk '{ print $1 }'); do
    ${VIRSH_PRIMARY} vol-delete --pool "${HTTPD_POOL_NAME}" "${VOLUME}" >/dev/null 2>&1 || true
  done
else
  echo "HTTPD pool absent; no HTTPD volumes to clean"
fi

echo "Removing obsolete pools on primary host..."
PRIMARY_INIT_POOLS=$(${VIRSH_PRIMARY} pool-list --all --name 2>&1) || {
  echo "ERROR: Failed to list initial pools on primary hypervisor: ${PRIMARY_INIT_POOLS}"
  exit 1
}
for POOL in $(echo "${PRIMARY_INIT_POOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)"); do
  ${VIRSH_PRIMARY} pool-destroy "${POOL}" >/dev/null 2>&1 || true
  ${VIRSH_PRIMARY} pool-delete "${POOL}" >/dev/null 2>&1 || true
  ${VIRSH_PRIMARY} pool-undefine "${POOL}" >/dev/null 2>&1 || true
done

echo "Removing stale networks on primary host..."
PRIMARY_INIT_NETS=$(${VIRSH_PRIMARY} net-list --all --name 2>&1) || {
  echo "ERROR: Failed to list initial networks on primary hypervisor: ${PRIMARY_INIT_NETS}"
  exit 1
}
for NET in $(echo "${PRIMARY_INIT_NETS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)"); do
  ${VIRSH_PRIMARY} net-destroy "${NET}" >/dev/null 2>&1 || true
  ${VIRSH_PRIMARY} net-undefine "${NET}" >/dev/null 2>&1 || true
done

# --- Clean Additional Host ---
ADD_INIT_DOMAINS=$(${VIRSH_ADDITIONAL} list --all --name 2>&1) || {
  echo "ERROR: Failed to list initial domains on additional hypervisor: ${ADD_INIT_DOMAINS}"
  exit 1
}
echo "Removing stale domains on additional host matching lease '${LEASED_RESOURCE}'..."
for DOMAIN in $(echo "${ADD_INIT_DOMAINS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)"); do
  ${VIRSH_ADDITIONAL} destroy "${DOMAIN}" >/dev/null 2>&1 || true
  sleep 1s
  ${VIRSH_ADDITIONAL} undefine "${DOMAIN}" >/dev/null 2>&1 || true
done

# Remove the job-owned additional libvirt network (bridge-forward to ocp*-amd / ocp2-arm)
# only after its domains are gone. Refuse removal if bridge does not match expectation.
ADDITIONAL_NETWORK_NAME="${LEASED_RESOURCE}"
ADD_CURRENT_NETS=$(${VIRSH_ADDITIONAL} net-list --all --name 2>/dev/null || true)
if echo "${ADD_CURRENT_NETS}" | grep -Fxq "${ADDITIONAL_NETWORK_NAME}"; then
  ADD_NET_BRIDGE=$(${VIRSH_ADDITIONAL} net-dumpxml "${ADDITIONAL_NETWORK_NAME}" 2>/dev/null |
    yq-v4 -p=xml --xml-attribute-prefix='@' -oy '.network.bridge."@name"' 2>/dev/null || true)
  EXPECTED_ADDITIONAL_BRIDGE="$(resolve_expected_additional_bridge)"
  EXPECTED_ADDITIONAL_BRIDGE="${EXPECTED_ADDITIONAL_BRIDGE//$'\n'/}"
  if [[ -z "${ADD_NET_BRIDGE}" || "${ADD_NET_BRIDGE}" == "null" || \
        -z "${EXPECTED_ADDITIONAL_BRIDGE}" || \
        "${ADD_NET_BRIDGE}" != "${EXPECTED_ADDITIONAL_BRIDGE}" ]]; then
    echo "ERROR: Additional network '${ADDITIONAL_NETWORK_NAME}' references bridge '${ADD_NET_BRIDGE}'," \
         " expected '${EXPECTED_ADDITIONAL_BRIDGE}'; refusing to remove" >&2
    exit 1
  fi
  echo "Removing additional libvirt network '${ADDITIONAL_NETWORK_NAME}' (bridge=${ADD_NET_BRIDGE}) on additional host..."
  ${VIRSH_ADDITIONAL} net-destroy "${ADDITIONAL_NETWORK_NAME}" >/dev/null 2>&1 || true
  ${VIRSH_ADDITIONAL} net-undefine "${ADDITIONAL_NETWORK_NAME}" >/dev/null 2>&1 || true
else
  echo "INFO: Additional libvirt network '${ADDITIONAL_NETWORK_NAME}' not found; nothing to remove"
fi

echo "Removing stale pool volumes on additional host..."
ADDITIONAL_POOL="${ADDITIONAL_POOL_NAME:-multiarch-ci-pool}"
if ${VIRSH_ADDITIONAL} pool-list 2>/dev/null | grep -qw "${ADDITIONAL_POOL}"; then
  ADD_INIT_VOLS=$(${VIRSH_ADDITIONAL} vol-list --pool "${ADDITIONAL_POOL}" 2>&1) || {
    echo "ERROR: Failed to list initial volumes on additional pool ${ADDITIONAL_POOL}: ${ADD_INIT_VOLS}"
    exit 1
  }
  for VOLUME in $(echo "${ADD_INIT_VOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" | awk '{ print $1 }'); do
    ${VIRSH_ADDITIONAL} vol-delete --pool "${ADDITIONAL_POOL}" "${VOLUME}" >/dev/null 2>&1 || true
  done
fi

# Detect conflicts (fail-closed if virsh listing encounters an error)
PRIMARY_LIST_DOMAINS=$(${VIRSH_PRIMARY} list --all --name 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list domains on primary hypervisor during conflict detection: ${PRIMARY_LIST_DOMAINS}"
  exit 1
fi
CONFLICTING_DOMAINS_P=$(echo "${PRIMARY_LIST_DOMAINS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" || true)

CONFLICTING_VOLUMES_P=""
if ${VIRSH_PRIMARY} pool-list 2>/dev/null | grep -qw "${POOL_NAME}"; then
  PRIMARY_VOLS=$(${VIRSH_PRIMARY} vol-list --pool "${POOL_NAME}" 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to list volumes on primary pool ${POOL_NAME}: ${PRIMARY_VOLS}"
    exit 1
  fi
  CONFLICTING_VOLUMES_P=$(echo "${PRIMARY_VOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" | awk '{ print $1 }' || true)
fi

CONFLICTING_HTTPD_VOLUMES_P=""
PRIMARY_VERIFY_ALL_POOLS=$(${VIRSH_PRIMARY} pool-list --all --name 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list pools on primary hypervisor during conflict verification: ${PRIMARY_VERIFY_ALL_POOLS}"
  exit 1
fi

if echo "${PRIMARY_VERIFY_ALL_POOLS}" | grep -Fxq "${HTTPD_POOL_NAME}"; then
  PRIMARY_HTTPD_VOLS=$(${VIRSH_PRIMARY} vol-list --pool "${HTTPD_POOL_NAME}" 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to list volumes on primary httpd pool ${HTTPD_POOL_NAME}: ${PRIMARY_HTTPD_VOLS}"
    exit 1
  fi
  CONFLICTING_HTTPD_VOLUMES_P=$(echo "${PRIMARY_HTTPD_VOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" | awk '{ print $1 }' || true)
else
  echo "HTTPD pool absent; no HTTPD volumes to check"
fi

PRIMARY_POOLS=$(${VIRSH_PRIMARY} pool-list --all --name 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list pools on primary hypervisor: ${PRIMARY_POOLS}"
  exit 1
fi
CONFLICTING_POOLS_P=$(echo "${PRIMARY_POOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" || true)

PRIMARY_NETS=$(${VIRSH_PRIMARY} net-list --all --name 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list networks on primary hypervisor: ${PRIMARY_NETS}"
  exit 1
fi
CONFLICTING_NETWORKS_P=$(echo "${PRIMARY_NETS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" || true)

ADD_LIST_DOMAINS=$(${VIRSH_ADDITIONAL} list --all --name 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list domains on additional hypervisor: ${ADD_LIST_DOMAINS}"
  exit 1
fi
CONFLICTING_DOMAINS_A=$(echo "${ADD_LIST_DOMAINS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" || true)

CONFLICTING_VOLUMES_A=""
if ${VIRSH_ADDITIONAL} pool-list 2>/dev/null | grep -qw "${ADDITIONAL_POOL}"; then
  ADD_VOLS=$(${VIRSH_ADDITIONAL} vol-list --pool "${ADDITIONAL_POOL}" 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to list volumes on additional pool ${ADDITIONAL_POOL}: ${ADD_VOLS}"
    exit 1
  fi
  CONFLICTING_VOLUMES_A=$(echo "${ADD_VOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" | awk '{ print $1 }' || true)
fi

ADD_NETS=$(${VIRSH_ADDITIONAL} net-list --all --name 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list networks on additional hypervisor: ${ADD_NETS}"
  exit 1
fi
CONFLICTING_NETWORKS_A=$(echo "${ADD_NETS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" || true)

set -e

if [ -n "${CONFLICTING_DOMAINS_P}" ] || [ -n "${CONFLICTING_VOLUMES_P}" ] || [ -n "${CONFLICTING_HTTPD_VOLUMES_P}" ] || [ -n "${CONFLICTING_POOLS_P}" ] || [ -n "${CONFLICTING_NETWORKS_P}" ] || [ -n "${CONFLICTING_DOMAINS_A}" ] || [ -n "${CONFLICTING_VOLUMES_A}" ] || [ -n "${CONFLICTING_NETWORKS_A}" ]; then
  echo "ERROR: Could not ensure clean state for lease ${LEASED_RESOURCE}"
  [[ -n "${CONFLICTING_DOMAINS_P}" ]] && echo "Conflicting primary domains found"
  [[ -n "${CONFLICTING_VOLUMES_P}" ]] && echo "Conflicting primary pool volumes found"
  [[ -n "${CONFLICTING_HTTPD_VOLUMES_P}" ]] && echo "Conflicting primary httpd volumes found"
  [[ -n "${CONFLICTING_POOLS_P}" ]] && echo "Conflicting primary pools found"
  [[ -n "${CONFLICTING_NETWORKS_P}" ]] && echo "Conflicting primary networks found"
  [[ -n "${CONFLICTING_DOMAINS_A}" ]] && echo "Conflicting additional domains found"
  [[ -n "${CONFLICTING_VOLUMES_A}" ]] && echo "Conflicting additional pool volumes found"
  [[ -n "${CONFLICTING_NETWORKS_A}" ]] && echo "Conflicting additional networks found"
  exit 1
fi

echo "Pre-cleanup completed cleanly for lease ${LEASED_RESOURCE} across primary and additional hypervisors."
