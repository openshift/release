#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

# Update shared vars with providers specific
cat >> "${SHARED_DIR}"/env << EOF
export OCI_CLI_CONFIG_FILE=/var/run/vault/opct-splat/opct-oci-splat-user-config
export OKD_INSTALLER_CLUSTER_PROFILE=ha
EOF

source "${SHARED_DIR}"/env


# Any provider specifics functions or custom config must be added here
cat >> "${SHARED_DIR}"/functions << EOF

function opct_upi_conf_provider() {
    mkdir -p $HOME/.oci
    ln -svf $OCI_CLI_CONFIG_FILE $HOME/.oci/config
    oci_user_id=$(grep ^user "${OCI_CLI_CONFIG_FILE}" | awk -F '=' '{print$2}')
    ANSIBLE_LOG_PATH=/tmp/runner.log ansible localhost -m oracle.oci.oci_identity_user_facts -a user_id="\${oci_user_id-}" > /dev/null && echo authenticated
}
EOF