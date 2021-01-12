#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source ${CLUSTER_PROFILE_DIR}/ovirt.conf
# We want the setup to download the latest CA from the engine
# Therefor living it empty
cat > ${SHARED_DIR}/ovirt-config.yaml <<EOF
ovirt_url: ${OVIRT_ENGINE_URL}
ovirt_username: ${OVIRT_ENGINE_USERNAME}
ovirt_password: ${OVIRT_ENGINE_PASSWORD}
ovirt_cafile: ""
ovirt_insecure: true
EOF
