#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

declare -a vips
mapfile -t vips <"${SHARED_DIR}"/vips.txt
/tmp/yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<<"
platform:
  vsphere:
    apiVIP: ${vips[0]}
    ingressVIP: ${vips[1]}
"
