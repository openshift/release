#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export OCI_CLI_CONFIG_FILE=/var/run/vault/opct-splat/opct-oci-splat-user-config

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}


function upi_conf_provider() {
  echo_date "Installing oci-cli"
  if [[ ! -d "$HOME"/.oci ]]; then
    mkdir -p "$HOME"/.oci
  fi
  ln -svf "$OCI_CONFIG" "$HOME"/.oci/config
  python3 -m venv "${WORKDIR}"/venv-oci && source "${WORKDIR}"/venv-oci/bin/activate
  "${VENV}"/bin/pip install -U pip > /dev/null
  "${VENV}"/bin/pip install -U oci-cli > /dev/null
  $OCI_BIN setup repair-file-permissions --file "$HOME"/.oci/config || true
  export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
}
upi_conf_provider

source "${SHARED_DIR}/infra_resources.env"

# Destroy bootsap
oci compute-management instance-pool terminate --force \
  --instance-pool-id $INSTANCE_POOL_ID \
    --wait-for-state TERMINATED
oci compute-management instance-configuration delete --force \
  --instance-configuration-id $INSTANCE_CONFIG_ID