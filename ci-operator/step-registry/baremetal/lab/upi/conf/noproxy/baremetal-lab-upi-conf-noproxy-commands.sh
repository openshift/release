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

# API names from install-config (like old ipi-conf-proxy)
BASE_DOMAIN="$(yq e '.baseDomain' "${CONFIG}")"
CLUSTER_NAME="$(yq e '.metadata.name' "${CONFIG}")"

[[ -n "${BASE_DOMAIN}" ]] && NO_PROXY="${NO_PROXY},.${BASE_DOMAIN}"
if [[ -n "${CLUSTER_NAME}" && -n "${BASE_DOMAIN}" ]]; then
  NO_PROXY="${NO_PROXY},api.${CLUSTER_NAME}.${BASE_DOMAIN},api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"
fi

echo "Configured noProxy: ${NO_PROXY}"

# Write patch file — install step merges *_patch_install_config.yaml later
cat > "${OUTPUT}" <<EOF
proxy:
  noProxy: ${NO_PROXY}
EOF

echo "Created ${OUTPUT}"