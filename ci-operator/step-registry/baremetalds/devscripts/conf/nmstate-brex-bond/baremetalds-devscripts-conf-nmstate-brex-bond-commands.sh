#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf nmstate-brex-bond command ************"

echo "NETWORK_CONFIG_FOLDER=/root/dev-scripts/network-configs/bond" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "ASSETS_EXTRA_FOLDER=/root/dev-scripts/network-configs/nmstate-brex-bond" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "BOND_PRIMARY_INTERFACE=true" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "EXTRA_NETWORK_NAMES=\"nmstate1 nmstate2\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE1_NETWORK_SUBNET_V4=\"192.168.221.0/24\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE1_NETWORK_SUBNET_V6=\"fd2e:6f44:5dd8:ca56::/120\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE2_NETWORK_SUBNET_V4=\"192.168.222.0/24\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
echo "NMSTATE2_NETWORK_SUBNET_V6=\"fd2e:6f44:5dd8:cc56::/120\"" >> "${SHARED_DIR}/dev-scripts-additional-config"
