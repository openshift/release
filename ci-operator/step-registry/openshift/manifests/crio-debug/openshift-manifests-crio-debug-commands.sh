#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Configuring cri-o with debug logging...."

for ROLE in master worker
do
  cat >> "${SHARED_DIR}/manifest_crio_debug_logging_${ROLE}.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: ContainerRuntimeConfig
metadata:
 name: custom-loglevel-${ROLE}
spec:
 machineConfigPoolSelector:
  matchLabels:
   pools.operator.machineconfiguration.openshift.io/${ROLE}: ""
 containerRuntimeConfig:
   logLevel: debug
EOF

  echo "manifest_crio_debug_logging_${ROLE}.yaml"
  echo "---------------------------------------------"
  cat "${SHARED_DIR}/manifest_crio_debug_logging_${ROLE}.yaml"
done
