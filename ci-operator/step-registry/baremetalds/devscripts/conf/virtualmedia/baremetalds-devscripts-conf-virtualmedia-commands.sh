#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf virtualmedia command ************"

echo "export IP_STACK=v4" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "export PROVISIONING_NETWORK_PROFILE=Disabled" >> "${SHARED_DIR}/dev-scripts-additional-config"