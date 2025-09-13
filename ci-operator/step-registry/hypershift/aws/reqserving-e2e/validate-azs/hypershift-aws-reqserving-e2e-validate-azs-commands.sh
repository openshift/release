#!/bin/bash

set -euo pipefail

max_zones_count=$(cat "${SHARED_DIR}/maxzonescount")
if [[ ${max_zones_count} -lt ${ZONES_COUNT} ]]; then
  echo "max_zones_count is less than ZONES_COUNT"
  exit 1
fi

echo "max_zones_count is greater than or equal to ZONES_COUNT"
exit 0
