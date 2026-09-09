#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

if [ -z "${LOGGING_TLS_PROFILE_CONFIG:-}" ]; then
  echo "[ERROR] LOGGING_TLS_PROFILE_CONFIG is missing"
  exit 1
fi

# Ensure the provided value is valid JSON
if ! echo "$LOGGING_TLS_PROFILE_CONFIG" | jq -e . >/dev/null 2>&1; then
  echo "[ERROR] LOGGING_TLS_PROFILE_CONFIG is not valid JSON"
  exit 1
fi

patch_tlssecurityprofile_config() {
  local desired_tls_config="$1"

  echo "[INFO] Patching tlsSecurityProfile..."
  oc patch apiserver/cluster --type=merge -p "{\"spec\": {\"tlsSecurityProfile\": $desired_tls_config}}"

  echo "[INFO] Waiting for cluster to stabilize..."
  oc adm wait-for-stable-cluster

  # Normalize (compact + sort keys) before comparing to avoid false diffs
  local current_config desired_config
  current_config=$(oc get apiserver/cluster -o json | jq -cS '.spec.tlsSecurityProfile')
  desired_config=$(echo "$desired_tls_config" | jq -cS '.')

  if [[ "$current_config" != "$desired_config" ]]; then
    echo "[ERROR] tlsSecurityProfile does not match desired configuration."
    echo "---- Desired:"
    echo "$desired_config" | jq .
    echo "---- Current:"
    echo "$current_config" | jq .
    exit 1
  fi

}

set_proxy
patch_tlssecurityprofile_config "$LOGGING_TLS_PROFILE_CONFIG"

