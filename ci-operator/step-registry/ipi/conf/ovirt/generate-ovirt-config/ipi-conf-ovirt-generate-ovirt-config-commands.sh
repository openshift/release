#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source ${CLUSTER_PROFILE_DIR}/ovirt.conf

# TODO: MOVE TO SECURE
#ca_bundle=$(curl "${OVIRT_PEM_URL}")

cat > ${SHARED_DIR}/ovirt-config.yaml <<EOF
ovirt_url: ${OVIRT_ENGINE_URL}
ovirt_username: ${OVIRT_ENGINE_USERNAME}
ovirt_password: ${OVIRT_ENGINE_PASSWORD}
ovirt_insecure: true
ovirt_cafile: ""
EOF
