#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

vnc_password="$(<"/var/run/idrac-vnc-password/idrac-vnc-password")"
payload="$(jq -nc --arg pwd "${vnc_password}" '{
  Attributes: {
    "VNCServer.1.Enable": "Enabled",
    "VNCServer.1.Timeout": 10800,
    "VNCServer.1.Password": $pwd
  }
}')"

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  curl --fail --silent --show-error -k -u "${bmc_user}:${bmc_pass}" -X PATCH "https://${bmc_address}/redfish/v1/Managers/iDRAC.Embedded.1/Attributes" \
     -H 'Content-Type: application/json' \
     -H 'Accept: application/json' \
     -d "${payload}"
done