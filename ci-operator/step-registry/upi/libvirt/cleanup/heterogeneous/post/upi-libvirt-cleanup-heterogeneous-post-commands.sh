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

require_commands yq-v4 mock-nss.sh virsh grep awk sleep ssh

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

# ---------------------------------------------------------------------------
# SSH helper for primary hypervisor host operations (ip link, alias check).
# Credentials are provisioned by infra in the cluster profile.
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
    "root@${HOSTNAME_PRIMARY}" \
    "$@"
}

# Read VXLAN config for ownership checks
VXLAN_INTERFACE="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".vxlan.interface" "${LEASE_CONF}")"
VXLAN_ID="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".vxlan.id" "${LEASE_CONF}")"
VXLAN_REMOTE_IP="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".vxlan.remote-ip" "${LEASE_CONF}")"
VXLAN_PORT="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".vxlan.dstport" "${LEASE_CONF}")"
EXPECTED_VXLAN_OWNER="ci:${LEASED_RESOURCE}"

echo "Verifying libvirt connectivity to primary and additional hypervisors..."
if ! ${VIRSH_PRIMARY} list >/dev/null; then
  echo "ERROR: Failed to connect or list domains on primary hypervisor"
  exit 1
fi

if ! ${VIRSH_ADDITIONAL} list >/dev/null; then
  echo "ERROR: Failed to connect or list domains on additional hypervisor"
  exit 1
fi

CLEANUP_FAILED=0
VXLAN_CLEANUP_FAILED=0

set +e

# --- Clean Primary Host ---
echo "Removing stale domains on primary host matching lease '${LEASED_RESOURCE}'..."
PRIMARY_INIT_DOMAINS=$(${VIRSH_PRIMARY} list --all --name 2>&1) || {
  echo "ERROR: Failed to list initial domains on primary hypervisor: ${PRIMARY_INIT_DOMAINS}"
  exit 1
}

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
  for VOLUME in $(echo "${PRIMARY_INIT_VOLS}" | awk '{ print $1 }' | grep -E "^${LEASED_RESOURCE}([-.]|$)"); do
    echo "Deleting primary pool volume: ${VOLUME}"
    if ! ${VIRSH_PRIMARY} vol-delete --pool "${POOL_NAME}" "${VOLUME}"; then
      echo "ERROR: Could not delete ${VOLUME} from ${POOL_NAME}" >&2
      CLEANUP_FAILED=1
    fi
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
  for VOLUME in $(echo "${PRIMARY_INIT_HTTPD_VOLS}" | awk '{ print $1 }' | grep -E "^${LEASED_RESOURCE}([-.]|$)"); do
    echo "Deleting primary httpd pool volume: ${VOLUME}"
    if ! ${VIRSH_PRIMARY} vol-delete --pool "${HTTPD_POOL_NAME}" "${VOLUME}"; then
      echo "ERROR: Could not delete ${VOLUME} from ${HTTPD_POOL_NAME}" >&2
      CLEANUP_FAILED=1
    fi
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

# --- Clean Additional Host (ARM domains and network) ---
ADD_INIT_DOMAINS=$(${VIRSH_ADDITIONAL} list --all --name 2>&1) || {
  echo "ERROR: Failed to list initial domains on additional hypervisor: ${ADD_INIT_DOMAINS}"
  exit 1
}
echo "Removing stale domains on additional host matching lease '${LEASED_RESOURCE}'..."
for DOMAIN in $(echo "${ADD_INIT_DOMAINS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)"); do
  # Destroy if running
  ${VIRSH_ADDITIONAL} destroy "${DOMAIN}" >/dev/null 2>&1 || true
  sleep 1s
  # For persistent UEFI domains, undefine with --nvram to clean firmware state.
  # If the domain has already disappeared (transient that self-deleted), that is
  # not an error. Capture and record any actual undefine failure.
  if ${VIRSH_ADDITIONAL} dominfo "${DOMAIN}" >/dev/null 2>&1; then
    if ! ${VIRSH_ADDITIONAL} undefine "${DOMAIN}" --nvram >/dev/null 2>&1; then
      # Fall back to plain undefine (non-UEFI or NVRAM already gone)
      if ! ${VIRSH_ADDITIONAL} undefine "${DOMAIN}" >/dev/null 2>&1; then
        echo "ERROR: Failed to undefine domain ${DOMAIN} on additional hypervisor" >&2
        CLEANUP_FAILED=1
      fi
    fi
  else
    echo "INFO: Domain ${DOMAIN} already gone (transient or previously cleaned)"
  fi
done

# Remove the job-owned ARM libvirt network only after all its domains are deleted.
# Verify the network references the expected infrastructure bridge before removal.
ARM_NETWORK_NAME="${LEASED_RESOURCE}"
ADD_CURRENT_NETS=$(${VIRSH_ADDITIONAL} net-list --all --name 2>/dev/null || true)
if echo "${ADD_CURRENT_NETS}" | grep -Fxq "${ARM_NETWORK_NAME}"; then
  ARM_NET_BRIDGE=$(${VIRSH_ADDITIONAL} net-dumpxml "${ARM_NETWORK_NAME}" 2>/dev/null |
    yq-v4 -p=xml --xml-attribute-prefix='@' -oy '.network.bridge."@name"' 2>/dev/null || true)
  EXPECTED_ARM_BRIDGE="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".vxlan.\"additional-bridge\"" "${LEASE_CONF}" 2>/dev/null || true)"
  if [[ -z "${ARM_NET_BRIDGE}" || "${ARM_NET_BRIDGE}" == "null" || \
        "${ARM_NET_BRIDGE}" != "${EXPECTED_ARM_BRIDGE}" ]]; then
    echo "ERROR: ARM network '${ARM_NETWORK_NAME}' references bridge '${ARM_NET_BRIDGE}'," \
         " expected '${EXPECTED_ARM_BRIDGE}'; refusing to remove" >&2
    CLEANUP_FAILED=1
  else
    echo "Removing ARM libvirt network '${ARM_NETWORK_NAME}' (bridge=${ARM_NET_BRIDGE}) on additional host..."
    ${VIRSH_ADDITIONAL} net-destroy "${ARM_NETWORK_NAME}" >/dev/null 2>&1 || true
    if ! ${VIRSH_ADDITIONAL} net-undefine "${ARM_NETWORK_NAME}" >/dev/null 2>&1; then
      echo "ERROR: Failed to undefine ARM network '${ARM_NETWORK_NAME}'" >&2
      CLEANUP_FAILED=1
    fi
  fi
else
  echo "INFO: ARM libvirt network '${ARM_NETWORK_NAME}' not found; nothing to remove"
fi

echo "Removing stale pool volumes on additional host..."
ADDITIONAL_POOL="${ADDITIONAL_POOL_NAME:-multiarch-ci-pool}"
if ${VIRSH_ADDITIONAL} pool-list 2>/dev/null | grep -qw "${ADDITIONAL_POOL}"; then
  ADD_INIT_VOLS=$(${VIRSH_ADDITIONAL} vol-list --pool "${ADDITIONAL_POOL}" 2>&1) || {
    echo "ERROR: Failed to list initial volumes on additional pool ${ADDITIONAL_POOL}: ${ADD_INIT_VOLS}"
    exit 1
  }
  for VOLUME in $(echo "${ADD_INIT_VOLS}" | awk '{ print $1 }' | grep -E "^${LEASED_RESOURCE}([-.]|$)"); do
    echo "Deleting additional pool volume: ${VOLUME}"
    if ! ${VIRSH_ADDITIONAL} vol-delete --pool "${ADDITIONAL_POOL}" "${VOLUME}"; then
      echo "ERROR: Could not delete ${VOLUME} from ${ADDITIONAL_POOL}" >&2
      CLEANUP_FAILED=1
    fi
  done
fi

# ---------------------------------------------------------------------------
# Clean primary VXLAN endpoint — must happen after ARM network is gone.
# Before deleting, verify the endpoint is job-owned and matches expected config.
# Preserve infra-owned ocp2-arm bridge, persistent vxlan2, and NetworkManager
# connections — only remove the job-owned endpoint.
# ---------------------------------------------------------------------------
if [[ -n "${VXLAN_INTERFACE}" && "${VXLAN_INTERFACE}" != "null" ]]; then
  echo "Checking for job-owned primary VXLAN endpoint '${VXLAN_INTERFACE}'..."
  VXLAN_PRESENT=$(run_primary test -e "/sys/class/net/${VXLAN_INTERFACE}" && echo yes || echo no)
  if [[ "${VXLAN_PRESENT}" == "yes" ]]; then
    # Check ownership alias
    ACTUAL_ALIAS=$(run_primary ip link show "${VXLAN_INTERFACE}" 2>/dev/null |
      grep -oP '(?<=alias )\S+' | head -1 || true)
    if [[ "${ACTUAL_ALIAS}" != "${EXPECTED_VXLAN_OWNER}" ]]; then
      echo "ERROR: VXLAN endpoint '${VXLAN_INTERFACE}' alias is '${ACTUAL_ALIAS}'," \
           " expected '${EXPECTED_VXLAN_OWNER}'; refusing to delete (report for reconciliation)" >&2
      VXLAN_CLEANUP_FAILED=1
    else
      # Verify VNI, remote, and dstport match lease before destroying
      ACTUAL_VNI=$(run_primary ip -d link show "${VXLAN_INTERFACE}" 2>/dev/null |
        grep -oP 'id \K[0-9]+' | head -1 || true)
      ACTUAL_REMOTE=$(run_primary ip -d link show "${VXLAN_INTERFACE}" 2>/dev/null |
        grep -oP 'remote \K[0-9.]+' | head -1 || true)
      ACTUAL_PORT=$(run_primary ip -d link show "${VXLAN_INTERFACE}" 2>/dev/null |
        grep -oP 'dstport \K[0-9]+' | head -1 || true)

      if [[ "${ACTUAL_VNI}" != "${VXLAN_ID}" || \
            "${ACTUAL_REMOTE}" != "${VXLAN_REMOTE_IP}" || \
            "${ACTUAL_PORT}" != "${VXLAN_PORT}" ]]; then
        echo "ERROR: VXLAN endpoint '${VXLAN_INTERFACE}' config mismatch" \
             "(vni=${ACTUAL_VNI}/${VXLAN_ID}, remote=${ACTUAL_REMOTE}/${VXLAN_REMOTE_IP}," \
             " port=${ACTUAL_PORT}/${VXLAN_PORT}); refusing to delete (report for reconciliation)" >&2
        VXLAN_CLEANUP_FAILED=1
      else
        echo "Removing job-owned VXLAN endpoint '${VXLAN_INTERFACE}' from primary hypervisor..."
        run_primary bash -s -- "${VXLAN_INTERFACE}" <<'DEL_VXLAN'
set -euo pipefail
iface=$1
ip link set dev "${iface}" down 2>/dev/null || true
ip link delete "${iface}"
DEL_VXLAN
        # Verify absence
        if run_primary test -e "/sys/class/net/${VXLAN_INTERFACE}" 2>/dev/null; then
          echo "ERROR: VXLAN endpoint '${VXLAN_INTERFACE}' still exists after delete" >&2
          VXLAN_CLEANUP_FAILED=1
        else
          echo "INFO: VXLAN endpoint '${VXLAN_INTERFACE}' successfully removed"
        fi
      fi
    fi
  else
    echo "INFO: VXLAN endpoint '${VXLAN_INTERFACE}' not present; nothing to remove"
  fi
else
  echo "INFO: No VXLAN interface configured in lease; skipping VXLAN cleanup"
fi

# --- Now remove primary libvirt network (after ARM and VXLAN cleanup) ---
echo "Removing stale networks on primary host..."
PRIMARY_INIT_NETS=$(${VIRSH_PRIMARY} net-list --all --name 2>&1) || {
  echo "ERROR: Failed to list initial networks on primary hypervisor: ${PRIMARY_INIT_NETS}"
  exit 1
}
for NET in $(echo "${PRIMARY_INIT_NETS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)"); do
  ${VIRSH_PRIMARY} net-destroy "${NET}" >/dev/null 2>&1 || true
  ${VIRSH_PRIMARY} net-undefine "${NET}" >/dev/null 2>&1 || true
done

# Detect conflicts (fail-closed if virsh listing encounters an error)
PRIMARY_LIST_DOMAINS=$(${VIRSH_PRIMARY} list --all --name 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list domains on primary hypervisor during conflict detection: ${PRIMARY_LIST_DOMAINS}"
  exit 1
fi
CONFLICTING_DOMAINS_P=$(echo "${PRIMARY_LIST_DOMAINS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" || true)

PRIMARY_VOLS=$(${VIRSH_PRIMARY} vol-list --pool "${POOL_NAME}" 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list volumes on primary pool ${POOL_NAME}: ${PRIMARY_VOLS}"
  exit 1
fi
CONFLICTING_VOLUMES_P=$(
  echo "${PRIMARY_VOLS}" |
    awk '{ print $1 }' |
    grep -E "^${LEASED_RESOURCE}([-.]|$)" || true
)

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
  CONFLICTING_HTTPD_VOLUMES_P=$(
    echo "${PRIMARY_HTTPD_VOLS}" |
      awk '{ print $1 }' |
      grep -E "^${LEASED_RESOURCE}([-.]|$)" || true
  )
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

ADD_VOLS=$(${VIRSH_ADDITIONAL} vol-list --pool "${ADDITIONAL_POOL}" 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list volumes on additional pool ${ADDITIONAL_POOL}: ${ADD_VOLS}"
  exit 1
fi
CONFLICTING_VOLUMES_A=$(
  echo "${ADD_VOLS}" |
    awk '{ print $1 }' |
    grep -E "^${LEASED_RESOURCE}([-.]|$)" || true
)

# Check for remaining job-owned ARM networks on additional hypervisor
ADD_NETS_VERIFY=$(${VIRSH_ADDITIONAL} net-list --all --name 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list networks on additional hypervisor: ${ADD_NETS_VERIFY}"
  exit 1
fi
CONFLICTING_ARM_NETS_A=$(echo "${ADD_NETS_VERIFY}" | grep -Fxq "${ARM_NETWORK_NAME}" && echo "${ARM_NETWORK_NAME}" || true)

set -e

if [ -n "${CONFLICTING_DOMAINS_P}" ] || [ -n "${CONFLICTING_VOLUMES_P}" ] || \
   [ -n "${CONFLICTING_HTTPD_VOLUMES_P}" ] || [ -n "${CONFLICTING_POOLS_P}" ] || \
   [ -n "${CONFLICTING_NETWORKS_P}" ] || [ -n "${CONFLICTING_DOMAINS_A}" ] || \
   [ -n "${CONFLICTING_VOLUMES_A}" ] || [ -n "${CONFLICTING_ARM_NETS_A}" ] || \
   [ "${CLEANUP_FAILED}" -ne 0 ] || [ "${VXLAN_CLEANUP_FAILED}" -ne 0 ]; then
  echo "ERROR: Could not ensure clean state for lease ${LEASED_RESOURCE}"
  [[ -n "${CONFLICTING_DOMAINS_P}" ]]      && echo "Conflicting primary domains found"
  [[ -n "${CONFLICTING_VOLUMES_P}" ]]      && echo "Conflicting primary pool volumes found"
  [[ -n "${CONFLICTING_HTTPD_VOLUMES_P}" ]] && echo "Conflicting primary httpd volumes found"
  [[ -n "${CONFLICTING_POOLS_P}" ]]        && echo "Conflicting primary pools found"
  [[ -n "${CONFLICTING_NETWORKS_P}" ]]     && echo "Conflicting primary networks found"
  [[ -n "${CONFLICTING_DOMAINS_A}" ]]      && echo "Conflicting additional domains found"
  [[ -n "${CONFLICTING_VOLUMES_A}" ]]      && echo "Conflicting additional pool volumes found"
  [[ -n "${CONFLICTING_ARM_NETS_A}" ]]     && echo "Conflicting ARM networks found on additional hypervisor"
  [[ "${VXLAN_CLEANUP_FAILED}" -ne 0 ]]   && echo "Primary VXLAN endpoint cleanup failed (ownership or config mismatch)"
  exit 1
fi

echo "Post-cleanup completed cleanly for lease ${LEASED_RESOURCE} across primary and additional hypervisors."
