#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "## Install yq"
curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq
echo "   yq installed"

/tmp/yq -i '.networking.networkType="OpenShiftSDN"' "${SHARED_DIR}/install-config.yaml"

echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml | grep -v "password\|username"