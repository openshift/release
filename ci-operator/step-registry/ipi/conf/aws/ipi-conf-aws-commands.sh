#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

expiration_date=$(date -d '4 hours' --iso=minutes --utc)

REGION="${LEASED_RESOURCE}"
case "${REGION}" in
us-east-1)
   ZONE_1=us-east-1b
   ZONE_2=us-east-1c;;
esac
echo "AWS region: ${REGION} (zones: ${ZONE_1:-${REGION}a} ${ZONE_2:-${REGION}b})"

cat >> "${CONFIG}" << EOF
baseDomain: origin-ci-int-aws.dev.rhcloud.com
controlPlane:
  name: master
  platform:
    aws:
      zones:
      - ${ZONE1:-${REGION}a}
      - ${ZONE2:-${REGION}b}
compute:
- name: worker
  platform:
    aws:
      type: ${COMPUTE_NODE_TYPE}
      zones:
      - ${ZONE1:-${REGION}a}
      - ${ZONE2:-${REGION}b}
platform:
  aws:
    region: ${REGION}
    userTags:
      expirationDate: ${expiration_date}
EOF
