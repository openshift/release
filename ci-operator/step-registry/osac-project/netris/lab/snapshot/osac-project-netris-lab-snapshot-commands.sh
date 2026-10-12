#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ netris-lab snapshot ************"
echo "OSAC_INSTALLER_IMAGE: ${OSAC_INSTALLER_IMAGE}"
echo "OSAC_OPERATOR_IMAGE: ${OSAC_OPERATOR_IMAGE}"
echo "FULFILLMENT_SERVICE_IMAGE: ${FULFILLMENT_SERVICE_IMAGE}"
echo "OSAC_AAP_EE_IMAGE: ${OSAC_AAP_EE_IMAGE}"
echo "REPO_NAME: ${REPO_NAME:-unknown}"
echo "PULL_HEAD_REF: ${PULL_HEAD_REF:-none}"
echo "-------------------------------------------"

# === Extract installer from image ===
echo "Extracting installer from image..."
timeout -s 9 10m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
    "${OSAC_INSTALLER_IMAGE}" << 'EXTRACT_EOF'
set -o nounset
set -o errexit
set -o pipefail

INSTALLER_IMAGE="$1"

podman pull --authfile /root/pull-secret "${INSTALLER_IMAGE}"
CID=$(podman create "${INSTALLER_IMAGE}")
rm -rf /opt/osac-installer
podman cp "${CID}:/installer" /opt/osac-installer
podman rm "${CID}"
echo "Extracted osac-installer to /opt/osac-installer"
EXTRACT_EOF

# === Build EXTRA_VARS JSON ===
EXTRA_VARS="{"
EXTRA_VARS+="\"osac_operator_image\":\"${OSAC_OPERATOR_IMAGE}\""
EXTRA_VARS+=",\"fulfillment_service_image\":\"${FULFILLMENT_SERVICE_IMAGE}\""
EXTRA_VARS+=",\"osac_aap_image\":\"${OSAC_AAP_EE_IMAGE}\""
EXTRA_VARS+=",\"osac_installer_skip_clone\":true"

# Pass the PR branch for the component being tested
if [[ -n "${PULL_HEAD_REF:-}" ]]; then
    case "${REPO_NAME:-}" in
        osac-operator)
            EXTRA_VARS+=",\"osac_operator_branch\":\"${PULL_HEAD_REF}\""
            ;;
        fulfillment-service)
            EXTRA_VARS+=",\"fulfillment_service_branch\":\"${PULL_HEAD_REF}\""
            ;;
        osac-aap)
            EXTRA_VARS+=",\"osac_aap_branch\":\"${PULL_HEAD_REF}\""
            ;;
        osac-installer)
            EXTRA_VARS+=",\"osac_installer_branch\":\"${PULL_HEAD_REF}\""
            ;;
    esac
fi

EXTRA_VARS+="}"

DEPLOY_CMD="make deploy-ocp-snapshot EXTRA_VARS='${EXTRA_VARS}'"
echo "Deploy command: ${DEPLOY_CMD}"

# === Restore OCP + OSAC snapshot with component images ===
timeout -s 9 170m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << EOF
set -o nounset
set -o errexit
set -o pipefail

cd /opt/netris-test-infra
${DEPLOY_CMD}
EOF

echo "netris-lab snapshot step finished successfully"
