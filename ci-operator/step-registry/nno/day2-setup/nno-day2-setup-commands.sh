#!/bin/bash
set -euo pipefail
udev_file="${CLUSTER_PROFILE_DIR}/doca1-udev-network-rules-base64"
e2e_env="${CLUSTER_PROFILE_DIR}/nno-e2e-env"
if [[ -f "${udev_file}" ]]; then
  DOCA1_UDEV_NETWORK_RULES_BASE64="$(tr -d '\n' < "${udev_file}")"
  export DOCA1_UDEV_NETWORK_RULES_BASE64
elif [[ -f "${e2e_env}" ]]; then
  udev_line="$(grep -E '^DOCA1_UDEV_NETWORK_RULES_BASE64=' "${e2e_env}" || true)"
  if [[ -n "${udev_line}" ]]; then
    export DOCA1_UDEV_NETWORK_RULES_BASE64="${udev_line#DOCA1_UDEV_NETWORK_RULES_BASE64=}"
  fi
fi
if [[ -z "${DOCA1_UDEV_NETWORK_RULES_BASE64:-}" ]]; then
  echo "DOCA1_UDEV_NETWORK_RULES_BASE64 is not set (need ${udev_file} or that key in nno-e2e-env)"
  exit 1
fi
export WAIT_FOR_WORKER_MCP=true
export WORKER_MCP_ROLLOUT_START_TIMEOUT=4m
export WORKER_MCP_ROLLOUT_TIMEOUT=40m
export WORKER_MCP_NAME=worker
make apply-manifests
