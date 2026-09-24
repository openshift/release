#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

NETWORK_PATCH="${SHARED_DIR}/network_patch_install_config.yaml"
CONFIG="${SHARED_DIR}/install-config.yaml"
OUTPUT="${SHARED_DIR}/noproxy_patch_install_config.yaml"

# Only proxy jobs need this step
if [[ "${CLUSTER_WIDE_PROXY:-false}" != "true" ]]; then
  echo "CLUSTER_WIDE_PROXY is not true; skipping noProxy patch."
  exit 0
fi

if [[ ! -f "${NETWORK_PATCH}" ]]; then
  echo "ERROR: ${NETWORK_PATCH} not found. Run baremetal-lab-upi-conf-network first."
  exit 1
fi

if [[ ! -f "${CONFIG}" ]]; then
  echo "ERROR: ${CONFIG} not found."
  exit 1
fi

# Same starting list as the old ipi-conf-proxy logic
NO_PROXY="localhost,127.0.0.1,::1,.cluster.local,.svc"

# Read CIDRs from network patch (this is the important fix — includes machine network)
CLUSTER_CIDRS=""
while IFS= read -r cidr; do
  [[ -n "${cidr}" ]] && CLUSTER_CIDRS="${CLUSTER_CIDRS:+$CLUSTER_CIDRS,}${cidr}"
done < <(yq e '.networking.clusterNetwork[].cidr' "${NETWORK_PATCH}")

SERVICE_CIDRS=""
while IFS= read -r cidr; do
  [[ -n "${cidr}" ]] && SERVICE_CIDRS="${SERVICE_CIDRS:+$SERVICE_CIDRS,}${cidr}"
done < <(yq e '.networking.serviceNetwork[]' "${NETWORK_PATCH}")

MACHINE_CIDRS=""
while IFS= read -r cidr; do
  [[ -n "${cidr}" ]] && MACHINE_CIDRS="${MACHINE_CIDRS:+$MACHINE_CIDRS,}${cidr}"
done < <(yq e '.networking.machineNetwork[].cidr' "${NETWORK_PATCH}")

[[ -n "${CLUSTER_CIDRS}" ]] && NO_PROXY="${NO_PROXY},${CLUSTER_CIDRS}"
[[ -n "${SERVICE_CIDRS}" ]] && NO_PROXY="${NO_PROXY},${SERVICE_CIDRS}"
[[ -n "${MACHINE_CIDRS}" ]] && NO_PROXY="${NO_PROXY},${MACHINE_CIDRS}"

# Prefer profile / SHARED_DIR — install-config may not have baseDomain yet at this step
if [[ ! -f "${CLUSTER_PROFILE_DIR}/base_domain" ]]; then
  echo "ERROR: ${CLUSTER_PROFILE_DIR}/base_domain not found"
  exit 1
fi
if [[ ! -f "${SHARED_DIR}/cluster_name" ]]; then
  echo "ERROR: ${SHARED_DIR}/cluster_name not found"
  exit 1
fi

BASE_DOMAIN="$(<"${CLUSTER_PROFILE_DIR}/base_domain")"
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"

# Trim whitespace / newlines just in case
BASE_DOMAIN="${BASE_DOMAIN//$'\n'/}"
CLUSTER_NAME="${CLUSTER_NAME//$'\n'/}"

if [[ -z "${BASE_DOMAIN}" || "${BASE_DOMAIN}" == "null" ]]; then
  echo "ERROR: empty or invalid BASE_DOMAIN='${BASE_DOMAIN}'"
  exit 1
fi
if [[ -z "${CLUSTER_NAME}" || "${CLUSTER_NAME}" == "null" ]]; then
  echo "ERROR: empty or invalid CLUSTER_NAME='${CLUSTER_NAME}'"
  exit 1
fi

NO_PROXY="${NO_PROXY},.${BASE_DOMAIN}"
NO_PROXY="${NO_PROXY},api.${CLUSTER_NAME}.${BASE_DOMAIN},api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"

echo "Configured noProxy: ${NO_PROXY}"

# Write patch file — install step merges *_patch_install_config.yaml later
cat > "${OUTPUT}" <<EOF
proxy:
  noProxy: ${NO_PROXY}
EOF

echo "Created ${OUTPUT}"