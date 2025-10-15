#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf nmstate-brex-bond command ************"

echo "ASSETS_EXTRA_FOLDER=./network-configs/nmstate-brex-bond" >> "${SHARED_DIR}/dev-scripts-additional-config"
