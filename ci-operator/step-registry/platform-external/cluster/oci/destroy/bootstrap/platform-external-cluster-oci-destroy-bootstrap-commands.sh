#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export OCI_CLI_CONFIG_FILE=/var/run/vault/opct-splat/opct-oci-splat-user-config
function upi_conf_provider() {
    mkdir -p $HOME/.oci
    ln -svf $OCI_CLI_CONFIG_FILE $HOME/.oci/config
}
upi_conf_provider

source "${SHARED_DIR}/infra_resources.env"

# Compute
## Clean up instances
oci compute instance terminate --force \
  --instance-id $INSTANCE_ID_BOOTSTRAP