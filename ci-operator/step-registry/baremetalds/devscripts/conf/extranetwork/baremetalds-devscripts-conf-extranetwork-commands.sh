#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf extra network command ************"

if [[ -n "${EXTRA_NETWORK_CONFIG:-}" ]]; then
  readarray -t config <<< "${EXTRA_NETWORK_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      echo "export ${var}" >> "${SHARED_DIR}/dev-scripts-additional-config"
    fi
  done
fi
