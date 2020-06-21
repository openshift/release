#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf dualstack command ************"

echo "export IP_STACK=v4v6" >> "${SHARED_DIR}/dev-scripts-additional-config"
