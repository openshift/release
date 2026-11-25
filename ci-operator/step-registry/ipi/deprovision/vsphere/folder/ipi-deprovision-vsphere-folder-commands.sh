#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare vsphere_datacenter
# shellcheck disable=SC1091
source "${SHARED_DIR}/vsphere_context.sh"
echo "$(date -u --rfc-3339=seconds) - Configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

FOLDER="/$vsphere_datacenter/vm/$vsphere_datacenter"
SUB_FOLDER="$FOLDER/${NAMESPACE}-${UNIQUE_HASH}"

if govc folder.info "$SUB_FOLDER"; then
  echo "Delete folder $SUB_FOLDER"
  govc object.destroy "$SUB_FOLDER"
fi
