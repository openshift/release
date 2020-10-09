#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

expiration_date=$(date -d '4 hours' --iso=minutes --utc)

case "$((RANDOM % 3))" in
0) aws_region=us-east-2;;
1) aws_region=us-west-1;;
2) aws_region=us-west-2;;
*) echo >&2 "invalid AWS region index"; exit 1;;
esac
echo "AWS region: ${aws_region} (zones: ${zone_1:-${aws_region}a} ${zone_2:-${aws_region}b})"

cat >> "${CONFIG}" << EOF
baseDomain: origin-ci-int-aws.dev.rhcloud.com
controlPlane:
  name: master
  platform:
    aws:
      zones:
      - ${zone_1:-${aws_region}a}
      - ${zone_2:-${aws_region}b}
compute:
- name: worker
  platform:
    aws:
      zones:
      - ${zone_1:-${aws_region}a}
      - ${zone_2:-${aws_region}b}
platform:
  aws:
    region: ${aws_region}
    userTags:
      expirationDate: ${expiration_date}
EOF
