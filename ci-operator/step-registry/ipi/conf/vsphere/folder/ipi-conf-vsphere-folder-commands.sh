#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ ${FOLDER} == "" ]]; then
  echo "FOLDER is not defined, skip config it"
  exit 0
fi

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

if [ "${FOLDER}" == "default" ]; then
  DC_FOLDER="/$vsphere_datacenter/vm/$vsphere_datacenter"
  if govc folder.info "$DC_FOLDER"; then
    echo "$DC_FOLDER already exist, no need to create"
  else
    govc folder.create "$DC_FOLDER"
  fi
  FOLDER_PATH="$DC_FOLDER/ci-${UNIQUE_HASH}-cluster"
else
  FOLDER_PATH="/$vsphere_datacenter/vm/$FOLDER"
fi

if govc folder.info "$FOLDER_PATH"; then
  echo "$FOLDER_PATH already exist, no need to create"
else
  govc folder.create "$FOLDER_PATH"
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/folder.yaml.patch"

cat >"${PATCH}" <<EOF
platform:
  vsphere:
    failureDomains:
    - topology:
        folder: "$FOLDER_PATH"
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
