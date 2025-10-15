#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf nmstate-brex command ************"

echo "IP_STACK=v4v6" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "ASSETS_EXTRA_FOLDER=./network-configs/nmstate-brex-bond" >> "${SHARED_DIR}/dev-scripts-additional-config"
