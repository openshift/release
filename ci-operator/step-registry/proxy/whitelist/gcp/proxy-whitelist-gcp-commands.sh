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

# https://docs.openshift.com/container-platform/4.17/installing/install_config/configuring-firewall.html#configuring-firewall

cat <<EOF > ${SHARED_DIR}/proxy_whitelist.txt
.googleapis.com
accounts.google.com
EOF

cp ${SHARED_DIR}/proxy_whitelist.txt ${ARTIFACT_DIR}/
