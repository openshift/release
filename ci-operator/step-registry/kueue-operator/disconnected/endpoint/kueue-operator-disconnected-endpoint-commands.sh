#!/usr/bin/env bash

set -e
set -u
set -o pipefail

# Capture the cluster API endpoint for DNS-fallback use by later steps
# (CI build-farm DNS intermittently returns NXDOMAIN for live clusters' API names).
# Assignments carry || true so failures cannot kill this step under set -e.
# Resolution is tool-independent: getent first, then the API IPs read from the
# cluster itself via oc (getent is not reliably present in every step image).
API_HOST=$(awk '/server: https:/ { sub(/.*server: https:\/\//, ""); sub(/:.*/, ""); print; exit }' "${SHARED_DIR}/kubeconfig") || true
API_IP=$(getent hosts "${API_HOST}" 2>/dev/null | awk 'NR==1 {print $1}') || true
API_IP_SOURCE="getent"
if [[ -z "${API_IP}" ]] && command -v oc >/dev/null 2>&1; then
    echo "getent did not resolve ${API_HOST}; trying oc get endpoints"
    if OC_OUT=$(oc get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}' 2>&1); then
        API_IP="${OC_OUT}"
        API_IP_SOURCE="oc endpoints"
    else
        echo "oc get endpoints failed: ${OC_OUT}"
    fi
fi
if [[ -n "${API_IP}" ]]; then
    echo "${API_IP} ${API_HOST}" > "${SHARED_DIR}/api_hosts_entry"
    echo "Saved API endpoint for DNS fallback (${API_IP_SOURCE}): ${API_IP} ${API_HOST}"
else
    echo "WARNING: could not resolve ${API_HOST}; DNS fallback entry not saved"
fi
