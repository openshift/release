#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

# Update shared vars with providers specific
cat >> "${SHARED_DIR}"/env << EOF
export AWS_CONFIG_FILE=/var/run/vault/opct-splat/opct-aws-user-config
export OKD_INSTALLER_CLUSTER_PROFILE=HighlyAvailable
export AWS_REGION=us-east-1
EOF

source "${SHARED_DIR}"/env


# Any provider specifics functions or custom config must be added here
cat >> "${SHARED_DIR}"/functions << EOF

function opct_upi_conf_provider() {
    mkdir -p $HOME/.aws
    ln -svf $AWS_CONFIG_FILE $HOME/.aws/config
    ansible localhost --connection local -m amazon.aws.aws_caller_info >/dev/null && echo authenticated
}
EOF