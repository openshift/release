#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -z "$MCO_CONF_DAY1_EXTENSIONS_MCPS" ]; then
  echo "No MachineConfigPools provided, skipping"
  exit 0
fi

if [ -z "$MCO_CONF_DAY1_EXTENSIONS" ]; then
  echo "No extensions to install, skipping"
  exit 0
fi

function create_manifests() {
  local MANIFESTS_DIR=$1
  local MCPS=$2
  local EXTENSIONS=$3

  for MACHINE_CONFIG_POOL in $MCPS; do
    MC_NAME="99-${MACHINE_CONFIG_POOL}-extensions"
    MANIFEST_NAME="manifest_mc-${MC_NAME}.yml"

    echo "Creating extensions MachineConfig manifest $MC_NAME for pool $MACHINE_CONFIG_POOL"
    echo "Extensions: $EXTENSIONS"

    cat > "${MANIFESTS_DIR}/${MANIFEST_NAME}" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $MACHINE_CONFIG_POOL
  name: $MC_NAME
spec:
  config:
    ignition:
      version: 3.1.0
  extensions:
EOF

    for ext in $EXTENSIONS; do
      echo "  - ${ext}" >> "${MANIFESTS_DIR}/${MANIFEST_NAME}"
    done

    cat "${MANIFESTS_DIR}/${MANIFEST_NAME}"
    echo ''

  done
}

create_manifests "$SHARED_DIR" "$MCO_CONF_DAY1_EXTENSIONS_MCPS" "$MCO_CONF_DAY1_EXTENSIONS"
