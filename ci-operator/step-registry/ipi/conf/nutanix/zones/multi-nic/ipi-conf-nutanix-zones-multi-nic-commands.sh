#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -f ${CLUSTER_PROFILE_DIR}/secrets.sh ]]; then
  NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
else
  NUTANIX_AUTH_PATH=/var/run/vault/nutanix/secrets.sh
fi
declare prism_element1_subnet_2
declare prism_element2_subnet_2
declare prism_element3_subnet_2
# shellcheck source=/dev/null
source "${NUTANIX_AUTH_PATH}"

CONFIG="${SHARED_DIR}/install-config.yaml"
yq-go w -i "${CONFIG}" 'platform.nutanix.failureDomains(name==failure-domain-1).subnetUUIDs[+]' "$prism_element1_subnet_2"
yq-go w -i "${CONFIG}" 'platform.nutanix.failureDomains(name==failure-domain-2).subnetUUIDs[+]' "$prism_element2_subnet_2"
yq-go w -i "${CONFIG}" 'platform.nutanix.failureDomains(name==failure-domain-3).subnetUUIDs[+]' "$prism_element3_subnet_2"
echo "Updated multi-nics in '${CONFIG}'."

echo "The updated multi-nics:"
yq-go r "${CONFIG}" platform.nutanix.failureDomains
