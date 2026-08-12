#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if [[ ! -f "${SHARED_DIR}/proxy_private_url" ]]; then
  echo "'${SHARED_DIR}/proxy_private_url' not found, abort." && exit 1
fi

CONFIG_PATCH="${SHARED_DIR}/proxy.yaml.patch"
CONFIG="${SHARED_DIR}/install-config.yaml"

proxy_private_url=$(< "${SHARED_DIR}/proxy_private_url")

# Build noProxy list
# Start with standard exclusions
NO_PROXY="localhost,127.0.0.1,::1,.cluster.local,.svc"

# Check for network configuration in patch file first (for baremetal labs)
NETWORK_PATCH="${SHARED_DIR}/network_patch_install_config.yaml"
if [ -f "${NETWORK_PATCH}" ]; then
  # Extract cluster network CIDRs from patch
  CLUSTER_CIDRS=$(yq-go r "${NETWORK_PATCH}" 'networking.clusterNetwork[*].cidr' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  [ -n "${CLUSTER_CIDRS}" ] && NO_PROXY="${NO_PROXY},${CLUSTER_CIDRS}"

  # Extract service network CIDRs from patch
  SERVICE_CIDRS=$(yq-go r "${NETWORK_PATCH}" 'networking.serviceNetwork[*]' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  [ -n "${SERVICE_CIDRS}" ] && NO_PROXY="${NO_PROXY},${SERVICE_CIDRS}"

  # Extract machine network CIDRs from patch
  MACHINE_CIDRS=$(yq-go r "${NETWORK_PATCH}" 'networking.machineNetwork[*].cidr' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  [ -n "${MACHINE_CIDRS}" ] && NO_PROXY="${NO_PROXY},${MACHINE_CIDRS}"
fi

# Add cluster domain and API endpoints from install-config
if [ -f "${CONFIG}" ]; then
  # Add base domain
  BASE_DOMAIN=$(yq-go r "${CONFIG}" 'baseDomain' 2>/dev/null)
  [ -n "${BASE_DOMAIN}" ] && NO_PROXY="${NO_PROXY},.${BASE_DOMAIN}"

  # Add cluster name for API endpoint
  CLUSTER_NAME=$(yq-go r "${CONFIG}" 'metadata.name' 2>/dev/null)
  [ -n "${CLUSTER_NAME}" ] && [ -n "${BASE_DOMAIN}" ] && NO_PROXY="${NO_PROXY},api.${CLUSTER_NAME}.${BASE_DOMAIN},api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"

  # Also try to get networks from install-config if not found in patch
  if [ -z "${CLUSTER_CIDRS}" ]; then
    CLUSTER_CIDRS=$(yq-go r "${CONFIG}" 'networking.clusterNetwork[*].cidr' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    [ -n "${CLUSTER_CIDRS}" ] && NO_PROXY="${NO_PROXY},${CLUSTER_CIDRS}"
  fi
  if [ -z "${SERVICE_CIDRS}" ]; then
    SERVICE_CIDRS=$(yq-go r "${CONFIG}" 'networking.serviceNetwork[*]' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    [ -n "${SERVICE_CIDRS}" ] && NO_PROXY="${NO_PROXY},${SERVICE_CIDRS}"
  fi
  if [ -z "${MACHINE_CIDRS}" ]; then
    MACHINE_CIDRS=$(yq-go r "${CONFIG}" 'networking.machineNetwork[*].cidr' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    [ -n "${MACHINE_CIDRS}" ] && NO_PROXY="${NO_PROXY},${MACHINE_CIDRS}"
  fi
fi

echo "Configured noProxy: ${NO_PROXY}"

cat > "${CONFIG_PATCH}" << EOF
proxy:
  httpProxy: ${proxy_private_url}
  noProxy: ${NO_PROXY}
EOF

if [[ "${ENABLE_HTTPS_PROXY}" == "yes" ]]; then
  if [[ ! -f "${SHARED_DIR}/proxy_private_https_url" ]]; then
    echo "'${SHARED_DIR}/proxy_private_https_url' not found, abort." && exit 1
  fi
  proxy_private_https_url=$(< "${SHARED_DIR}/proxy_private_https_url")
  cat >> "${CONFIG_PATCH}" << EOF
  httpsProxy: ${proxy_private_https_url}
  noProxy: ${NO_PROXY}
EOF
  additional_trust_bundle="${SHARED_DIR}/additional_trust_bundle"
  client_ca_file="/var/run/vault/mirror-registry/client_ca.crt"
  if ! grep -Fqz "$(cat "$client_ca_file")" "${additional_trust_bundle}" 2>/dev/null; then
    cat "$client_ca_file" >> "${additional_trust_bundle}"
    cat >> "${CONFIG_PATCH}" << EOF
additionalTrustBundle: |
`sed 's/^/  /g' "${additional_trust_bundle}"`
EOF
  else
    echo "CA certificate already present in ${additional_trust_bundle}"
  fi
else
  cat >> "${CONFIG_PATCH}" << EOF
  httpsProxy: ${proxy_private_url}
  noProxy: ${NO_PROXY}
EOF
fi

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
