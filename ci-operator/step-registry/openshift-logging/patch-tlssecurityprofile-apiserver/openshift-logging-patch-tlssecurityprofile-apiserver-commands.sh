#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [ -z "${LOGGING_CUSTOM_TLS_PROFILE_CONFIG:-}" ]; then
  echo "The tls security profile config is missing"
  exit 0
fi

if [ -z "${LOGGING_TLS_PROFILE_TYPE:-}" ]; then
  echo "The tls profile type is missing"
  exit 1
fi

function patch_custom_tlssecurityprofile_config(){
    local shared_dir="$1"
    local logging_tls_profile_json="$2"
    local logging_tls_profile_type="$3"

    oc patch apiserver/cluster --type=merge -p "{\"spec\": {\"tlsSecurityProfile\":$logging_tls_profile_json}}"

    oc adm wait-for-stable-cluster

    current_tls_profile=$(oc get apiserver/cluster -ojson | jq -r '.spec.tlsSecurityProfile.type')
    if [[ "$current_tls_profile" != "$logging_tls_profile_type" ]]; then
        echo "Error: TLS Security Profile currently set is '$current_tls_profile', expected value is '$logging_tls_profile_type'"
        exit 1
    fi
}

patch_custom_tlssecurityprofile_config "$SHARED_DIR" "$LOGGING_CUSTOM_TLS_PROFILE_CONFIG" "$LOGGING_TLS_PROFILE_TYPE"
