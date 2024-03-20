#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-failureDomains.yaml"

NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh

declare prism_element1_host
declare prism_element1_port
declare prism_element1_uuid
declare prism_element1_subnet
declare prism_element2_host
declare prism_element2_port
declare prism_element2_uuid
declare prism_element2_subnet
declare prism_element3_host
declare prism_element3_port
declare prism_element3_uuid
declare prism_element3_subnet
# shellcheck source=/dev/null
source "${NUTANIX_AUTH_PATH}"

failureDomains="- failure-domain-1\n        - failure-domain-2\n        - failure-domain-3"
if [[ "$SINGLE_ZONE" == "true" ]]; then
  failureDomains="- failure-domain-1"
fi

cat >"${PATCH}" <<EOF
platform:
  nutanix:
    defaultMachinePlatform:
      failureDomains:
        $failureDomains
    failureDomains:
    - name: failure-domain-1
      prismElement:
        uuid: $prism_element1_uuid
        endpoint:
          address: $prism_element1_host
          port: $prism_element1_port
      subnetUUIDs:
      - $prism_element1_subnet

    - name: failure-domain-2
      prismElement:
        uuid: $prism_element2_uuid
        endpoint:
          address: $prism_element2_host
          port: $prism_element2_port
      subnetUUIDs:
      - $prism_element2_subnet

    - name: failure-domain-3
      prismElement:
        uuid: $prism_element3_uuid
        endpoint:
          address: $prism_element3_host
          port: $prism_element3_port
      subnetUUIDs:
      - $prism_element3_subnet
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated failureDomains in '${CONFIG}'."
