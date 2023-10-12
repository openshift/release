#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

/tmp/yq -i '.networking.networkType="OpenShiftSDN"' "${SHARED_DIR}/install-config.yaml"


echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml | grep -v "password\|username\|pullSecret"
