#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf feature set command ************"

if [[ -n "${FEATURE_SET:-}" ]]; then
  echo "export FEATURE_SET=${FEATURE_SET}" >> "${SHARED_DIR}/dev-scripts-additional-config"
fi
