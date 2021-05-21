#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: OVNKubernetes
EOF
echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml

if [[ ! -z "${GATEWAY_MODE}" ]]; then
  echo "Overriding OVN gateway mode with \"${GATEWAY_MODE}\""
  cat >> "${SHARED_DIR}/manifest_cluster-network-00-gateway-mode.yaml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
    name: gateway-mode-config
    namespace: openshift-network-operator
data:
    mode: "${GATEWAY_MODE}"
immutable: true
EOF
  echo "manifest_cluster-network-00-gateway-mode.yaml"
  echo "---------------------------------------------"
  cat ${SHARED_DIR}/manifest_cluster-network-00-gateway-mode.yaml
fi
