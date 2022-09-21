#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source ${CLUSTER_PROFILE_DIR}/ovirt.conf

curl -k -s --retry 30 --retry-delay 30 -o "${SHARED_DIR}/ca.pem" ${OVIRT_ENGINE_URL::-4}/services/pki-resource?resource=ca-certificate

cat > ${SHARED_DIR}/ovirt-config.yaml <<EOF
ovirt_url: ${OVIRT_ENGINE_URL}
ovirt_username: ${OVIRT_ENGINE_USERNAME}
ovirt_password: ${OVIRT_ENGINE_PASSWORD}
ovirt_insecure: false
ovirt_cafile: "${SHARED_DIR}/ca.pem"
EOF
