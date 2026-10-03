#!/bin/bash

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

HOSTNAME_PRIMARY="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".hostname" "${CLUSTER_PROFILE_DIR}/leases")"
HOSTNAME_ADDITIONAL="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"hostname-additional\"" "${CLUSTER_PROFILE_DIR}/leases")"

if [[ -z "${HOSTNAME_PRIMARY}" || "${HOSTNAME_PRIMARY}" == "null" ]]; then
  echo "ERROR: Couldn't retrieve primary hostname from lease config"
  exit 1
fi

if [[ -z "${HOSTNAME_ADDITIONAL}" || "${HOSTNAME_ADDITIONAL}" == "null" ]]; then
  echo "ERROR: Couldn't retrieve additional hostname from lease config"
  exit 1
fi

ADDITIONAL_PORT="${ADDITIONAL_LIBVIRT_PORT:-16511}"
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
echo "Removing stale domains on primary host matching lease '${LEASED_RESOURCE}'..."
PRIMARY_INIT_DOMAINS=$(${VIRSH_PRIMARY} list --all --name 2>&1) || {
  echo "ERROR: Failed to list initial domains on primary hypervisor: ${PRIMARY_INIT_DOMAINS}"
  exit 1
}

# --- Clean Primary Host ---
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
if ${VIRSH_PRIMARY} pool-list 2>/dev/null | grep -qw "${HTTPD_POOL_NAME}"; then
  PRIMARY_INIT_HTTPD_VOLS=$(${VIRSH_PRIMARY} vol-list --pool "${HTTPD_POOL_NAME}" 2>&1) || {
    echo "ERROR: Failed to list initial volumes on primary httpd pool ${HTTPD_POOL_NAME}: ${PRIMARY_INIT_HTTPD_VOLS}"
    exit 1
  }
  for VOLUME in $(echo "${PRIMARY_INIT_HTTPD_VOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" | awk '{ print $1 }'); do
    ${VIRSH_PRIMARY} vol-delete --pool "${HTTPD_POOL_NAME}" "${VOLUME}" >/dev/null 2>&1 || true
  done
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

echo "Removing stale pool volumes on additional host..."
ADDITIONAL_POOL="${ADDITIONAL_POOL_NAME:-default}"
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

PRIMARY_VOLS=$(${VIRSH_PRIMARY} vol-list --pool "${POOL_NAME}" 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list volumes on primary pool ${POOL_NAME}: ${PRIMARY_VOLS}"
  exit 1
fi
CONFLICTING_VOLUMES_P=$(echo "${PRIMARY_VOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" | awk '{ print $1 }' || true)

PRIMARY_HTTPD_VOLS=$(${VIRSH_PRIMARY} vol-list --pool "${HTTPD_POOL_NAME}" 2>&1)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to list volumes on primary httpd pool ${HTTPD_POOL_NAME}: ${PRIMARY_HTTPD_VOLS}"
  exit 1
fi
CONFLICTING_HTTPD_VOLUMES_P=$(echo "${PRIMARY_HTTPD_VOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" | awk '{ print $1 }' || true)

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
CONFLICTING_VOLUMES_A=$(echo "${ADD_VOLS}" | grep -E "^${LEASED_RESOURCE}([-.]|$)" | awk '{ print $1 }' || true)

set -e

if [ -n "${CONFLICTING_DOMAINS_P}" ] || [ -n "${CONFLICTING_VOLUMES_P}" ] || [ -n "${CONFLICTING_HTTPD_VOLUMES_P}" ] || [ -n "${CONFLICTING_POOLS_P}" ] || [ -n "${CONFLICTING_NETWORKS_P}" ] || [ -n "${CONFLICTING_DOMAINS_A}" ] || [ -n "${CONFLICTING_VOLUMES_A}" ]; then
  echo "ERROR: Could not ensure clean state for lease ${LEASED_RESOURCE}"
  [[ -n "${CONFLICTING_DOMAINS_P}" ]] && echo "Conflicting primary domains found"
  [[ -n "${CONFLICTING_VOLUMES_P}" ]] && echo "Conflicting primary pool volumes found"
  [[ -n "${CONFLICTING_HTTPD_VOLUMES_P}" ]] && echo "Conflicting primary httpd volumes found"
  [[ -n "${CONFLICTING_POOLS_P}" ]] && echo "Conflicting primary pools found"
  [[ -n "${CONFLICTING_NETWORKS_P}" ]] && echo "Conflicting primary networks found"
  [[ -n "${CONFLICTING_DOMAINS_A}" ]] && echo "Conflicting additional domains found"
  [[ -n "${CONFLICTING_VOLUMES_A}" ]] && echo "Conflicting additional pool volumes found"
  exit 1
fi

echo "Post-cleanup completed cleanly for lease ${LEASED_RESOURCE} across primary and additional hypervisors."
