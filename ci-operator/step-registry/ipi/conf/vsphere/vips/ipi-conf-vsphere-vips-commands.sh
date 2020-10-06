#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

third_octet=$(grep -oP 'ci-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

echo "192.168.${third_octet}.2" >> "${SHARED_DIR}"/vips.txt
echo "192.168.${third_octet}.3" >> "${SHARED_DIR}"/vips.txt

echo "Reserved the following IP addresses..."
cat "${SHARED_DIR}"/vips.txt
