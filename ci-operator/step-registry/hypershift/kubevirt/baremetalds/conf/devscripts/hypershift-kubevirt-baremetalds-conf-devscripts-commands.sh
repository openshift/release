#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds conf devscripts command ************"

# Configurable options exposed as ENV vars
if [[ -n "${MIRROR_OLM_REMOTE_INDEX:-}" ]]; then
    echo "export MIRROR_OLM_REMOTE_INDEX='${MIRROR_OLM_REMOTE_INDEX}'" | tee -a "${SHARED_DIR}/dev-scripts-additional-config"
fi
