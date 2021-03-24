#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf IPv6 command ************"

echo "export IP_STACK=v6" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "export NETWORK_TYPE=OVNKubernetes" >> "${SHARED_DIR}/dev-scripts-additional-config"
