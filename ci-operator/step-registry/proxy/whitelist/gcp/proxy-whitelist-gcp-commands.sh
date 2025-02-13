#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# https://docs.openshift.com/container-platform/4.17/installing/install_config/configuring-firewall.html#configuring-firewall

cat <<EOF > ${SHARED_DIR}/proxy_whitelist.txt
.googleapis.com
accounts.google.com
EOF

cp ${SHARED_DIR}/proxy_whitelist.txt ${ARTIFACT_DIR}/
