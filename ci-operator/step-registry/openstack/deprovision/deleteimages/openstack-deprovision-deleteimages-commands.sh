#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail


if [[ -f "${SHARED_DIR}/DELETE_IMAGES" ]]; then
  while IFS= read -r IMAGEID
  do
    openstack image delete "$IMAGEID"  || true
  done < "${SHARED_DIR}"/DELETE_IMAGES
fi
