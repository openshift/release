#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# https://docs.openshift.com/container-platform/4.17/installing/install_config/configuring-firewall.html#configuring-firewall

if [[ "${ENABLE_GCP_CUSTOM_ENDPOINT}" == "yes" ]]; then
    cat <<EOF > ${SHARED_DIR}/proxy_whitelist.txt
.p.googleapis.com
EOF
else
    cat <<EOF > ${SHARED_DIR}/proxy_whitelist.txt
.googleapis.com
accounts.google.com
EOF
fi

cp ${SHARED_DIR}/proxy_whitelist.txt ${ARTIFACT_DIR}/
