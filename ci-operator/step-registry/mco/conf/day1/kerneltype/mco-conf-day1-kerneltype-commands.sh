#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if  [ "$MCO_CONF_DAY1_INSTALL_KERNEL_TYPE" == "" ]; then
  echo "This installation does not need to create any kerneltype manifest"
  exit 0
fi


function validate_params() {
  if  [ "$MCO_CONF_DAY1_INSTALL_KERNEL_MCPS" = "" ]; then
    echo "ERROR: No MachineConfigPool provided"
    exit 255
  fi

  if  [ "$MCO_CONF_DAY1_INSTALL_KERNEL_TYPE" != "realtime" ] && [ "$MCO_CONF_DAY1_INSTALL_KERNEL_TYPE" != "64k-pages" ]; then
    echo "ERROR: kerneltype '$MCO_CONF_DAY1_INSTALL_KERNEL_TYPE' is not allowed. Accepted values: [realtime, 64k-pages]"
    exit 255
  fi
}



function create_manifests() {
  local MANIFESTS_DIR=$1
  local KERNEL_MCPS=$2
  local KERNEL_TYPE=$3

  for MACHINE_CONFIG_POOL in $KERNEL_MCPS;do
    MC_NAME="99-$MACHINE_CONFIG_POOL-kernel-$KERNEL_TYPE"
    MANIFEST_NAME="manifest_mc-${MC_NAME}.yml"

    echo "Creating $KERNEL_TYPE kerneltype MachineConfig manifest $MC_NAME for pool $MACHINE_CONFIG_POOL"

    cat > "${MANIFESTS_DIR}/${MANIFEST_NAME}" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $MACHINE_CONFIG_POOL
  name: $MC_NAME
spec:
  kernelType: $KERNEL_TYPE
EOF
    cat "${MANIFESTS_DIR}/${MANIFEST_NAME}"
    echo ''

  done
}

validate_params

create_manifests "$SHARED_DIR" "$MCO_CONF_DAY1_INSTALL_KERNEL_MCPS" "$MCO_CONF_DAY1_INSTALL_KERNEL_TYPE"
