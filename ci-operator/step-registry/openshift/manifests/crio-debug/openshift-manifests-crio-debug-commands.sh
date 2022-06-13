#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Configuring cri-o with debug logging...."
cat >> "${SHARED_DIR}/manifest_crio_debug_logging.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: ContainerRuntimeConfig
metadata:
 name: custom-loglevel
spec:
 machineConfigSelector:
   matchExpressions:
     - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker,master]}
 containerRuntimeConfig:
   logLevel: debug
EOF

echo "manifest_crio_debug_logging.yaml"
echo "---------------------------------------------"
cat "${SHARED_DIR}/manifest_crio_debug_logging.yaml"
