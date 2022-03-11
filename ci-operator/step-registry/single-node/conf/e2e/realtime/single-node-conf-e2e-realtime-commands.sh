#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

filename="${SHARED_DIR}/manifest_single-node-realtime.yml"

# Create Machine config with only realtime kernel flag turned on
cat >"${filename}" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: realtime-master
spec:
  kernelType: realtime
EOF

echo "Created ${filename}"
cat ${filename}