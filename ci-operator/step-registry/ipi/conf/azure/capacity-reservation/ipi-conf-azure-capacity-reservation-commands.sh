#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

capres_rg_file="${SHARED_DIR}/capacity_reservation_rg"
crg_name_file="${SHARED_DIR}/capacity_reservation_group_name"
sub_id_file="${SHARED_DIR}/capacity_reservation_subscription_id"
zone_file="${SHARED_DIR}/capacity_reservation_zone"

for f in "${capres_rg_file}" "${crg_name_file}" "${sub_id_file}" "${zone_file}"; do
    if [[ ! -f "${f}" ]]; then
        echo "Required file ${f} not found, exiting..."
        exit 1
    fi
done

CAPRES_RG=$(< "${capres_rg_file}")
CRG_NAME=$(< "${crg_name_file}")
SUBSCRIPTION_ID=$(< "${sub_id_file}")
ZONE=$(< "${zone_file}")

echo "Patching install-config.yaml with capacity reservation group:"
echo "  resourceGroup: ${CAPRES_RG}"
echo "  name: ${CRG_NAME}"
echo "  subscriptionId: ${SUBSCRIPTION_ID}"
echo "  zone: ${ZONE}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-capacity-reservation.yaml.patch"

cat > "${PATCH}" << EOF
controlPlane:
  platform:
    azure:
      zones:
      - "${ZONE}"
      capacityReservationGroup:
        subscriptionId: ${SUBSCRIPTION_ID}
        resourceGroup: ${CAPRES_RG}
        name: ${CRG_NAME}
compute:
- platform:
    azure:
      zones:
      - "${ZONE}"
      capacityReservationGroup:
        subscriptionId: ${SUBSCRIPTION_ID}
        resourceGroup: ${CAPRES_RG}
        name: ${CRG_NAME}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "install-config.yaml patched successfully"
