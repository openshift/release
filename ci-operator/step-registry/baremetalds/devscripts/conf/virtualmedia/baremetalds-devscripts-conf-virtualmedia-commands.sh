#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf virtualmedia command ************"

echo "export PROVISIONING_NETWORK_PROFILE=Disabled" >> "${SHARED_DIR}/dev-scripts-additional-config"
