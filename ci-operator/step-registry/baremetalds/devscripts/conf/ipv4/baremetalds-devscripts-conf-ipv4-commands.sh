#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf ipv4 command ************"

echo "export IP_STACK=v4" >> "${SHARED_DIR}/dev-scripts-additional-config"
