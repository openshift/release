#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-failureDomains.yaml"

NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh

echo "--------------- config"
cat "$CONFIG"
echo "---------------- patch"
cat "$PATCH"

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

echo "--- prism_element1_host $prism_element1_host"
echo "--- prism_element1_port $prism_element1_port"
echo "--- prism_element1_uuid $prism_element1_uuid"
echo "--- prism_element1_subnet $prism_element1_subnet"
echo "--- prism_element2_host $prism_element2_host"
echo "--- prism_element2_port $prism_element2_port"
echo "--- prism_element2_uuid $prism_element2_uuid"
echo "--- prism_element2_subnet $prism_element2_subnet"
echo "--- prism_element3_host $prism_element3_host"
echo "--- prism_element3_port $prism_element3_port"
echo "--- prism_element3_uuid $prism_element3_uuid"
echo "--- prism_element3_subnet $prism_element3_subnet"

failureDomains="- failure-domain-1
        - failure-domain-2
        - failure-domain-3"
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
echo "Updated failureDomains in '${CONFIG}'"

if [[ "$COMPUTE_ZONE" != "" ]]; then
  PATCH="${SHARED_DIR}/install-config-failureDomains-compute.yaml"

  cat >"${PATCH}" <<EOF
compute:
- platform:
    nutanix:
      failureDomains:
$(
    for zone in $COMPUTE_ZONE; do
      echo "        - $zone"
    done
  )
EOF

  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated compute failureDomains in '${CONFIG}'"
fi

if [[ "$CONTROL_PLANE_ZONE" != "" ]]; then
  PATCH="${SHARED_DIR}/install-config-failureDomains-control-plane.yaml"

  cat >"${PATCH}" <<EOF
controlPlane:
  platform:
    nutanix:
      failureDomains:
$(
    for zone in $CONTROL_PLANE_ZONE; do
      echo "        - $zone"
    done
  )
EOF

  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated control plane failureDomains in '${CONFIG}'"
fi
