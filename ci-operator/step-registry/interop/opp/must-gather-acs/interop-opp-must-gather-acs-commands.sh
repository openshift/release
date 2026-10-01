#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

mkdir -p "${ARTIFACT_DIR}/acs-must-gather"

# Verify ACS is installed
ACS_CSV=$(oc get csv -n "${ACS_NAMESPACE}" \
  -l "operators.coreos.com/rhacs-operator.${ACS_NAMESPACE}=" \
  -o=jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${ACS_CSV}" ]]; then
    echo "WARNING: No ACS CSV found in namespace ${ACS_NAMESPACE} — skipping diagnostic collection."
    echo "SKIPPED: No ACS CSV found" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
    exit 0
fi

# Get Central route
CENTRAL_HOST=$(oc get route central -n "${ACS_NAMESPACE}" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)

if [[ -z "${CENTRAL_HOST}" ]]; then
    echo "WARNING: Central route not found in ${ACS_NAMESPACE} — skipping."
    echo "SKIPPED: No Central route" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
    exit 0
fi

# Retrieve admin password
ADMIN_PW=$(oc get secret central-htpasswd -n "${ACS_NAMESPACE}" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

if [[ -z "${ADMIN_PW}" ]]; then
    echo "WARNING: Cannot retrieve Central admin password — skipping."
    echo "SKIPPED: No admin credentials" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
    exit 0
fi

# Download diagnostic bundle via Central API
# (same endpoint roxctl central debug download-diagnostics uses)
echo "Downloading ACS diagnostic bundle from https://${CENTRAL_HOST}..."
HTTP_CODE=$(curl -sk -u "admin:${ADMIN_PW}" -w '%{http_code}' \
  "https://${CENTRAL_HOST}/v1/debug/diagnostics" \
  -o "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip")

if [[ "${HTTP_CODE}" == "200" ]] && \
   [[ -s "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip" ]]; then
    echo "ACS diagnostic bundle downloaded (HTTP ${HTTP_CODE})."
    cd "${ARTIFACT_DIR}/acs-must-gather"
    unzip -qo acs-diagnostic-bundle.zip -d diagnostic-bundle 2>/dev/null || true
else
    echo "WARNING: Diagnostic download failed (HTTP ${HTTP_CODE})."
    echo "FAILED: HTTP ${HTTP_CODE}" > "${ARTIFACT_DIR}/acs-must-gather/FAILED"
fi
